package Failover::Server::PeerManager;
use strict;
use warnings;
use Ref::Store;
use base qw(POE::Sugar::Attributes);

use POE;
use POE::Wheel::SocketFactory;
use Failover::Protocol;
use POE::Filter::JSON::Incr;
use Log::Fu;
use List::Util qw(first);

my $poe_kernel = 'POE::Kernel';
use Failover::Server::RFS;
use Failover::Server::Events;

my $Store = $Failover::Server::RFS::Store;

my $OBJ;

####### OUTBOUND CONNECTIONS TO PEERS ###########

sub peer_do_connect :Event(FO_EV_PEER_OCONN_INIT) {
    my $peer = $_[ARG0];
    my ($paddr,$pport) = split(/:/, $peer->ipaddr);
    $pport ||= 7979;
    my $conn = POE::Wheel::SocketFactory->new(
        RemoteAddress => $paddr,
        RemotePort => $pport,
        SuccessEvent => FO_EV_PEER_OCONN_OK,
        FailureEvent => FO_EV_PEER_OCONN_ERR
    );
    $peer->sock($conn);
    $Store->store($conn->ID, FO_RFS_LKEY_WID2WHEEL, $conn);
    $Store->store_kt($conn->ID, FO_RFS_LKEY_WID2PEER, $peer);
    if(!defined $peer->initial_alarm) {
        log_infof("Setting initial alarm for peer %s. Seconds %d",
                  $peer->id, FOPROTO_TIMEO_IDENT);
        my $aid = $poe_kernel->delay_set(
            FO_EV_PEER_OCONN_ALARM, FOPROTO_TIMEO_IDENT, $peer
        );
        $peer->initial_alarm($aid);
    }
}

sub peer_connect_ok :Event(FO_EV_PEER_OCONN_OK) {
    
    my ($newsock,$wid) = @_[ARG0,ARG3];
    my $peer = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2PEER);
    log_infof("Connected to peer %s", $peer->infostring);
    $OBJ->peer_sock_init($peer, $newsock);    
}

sub peer_connect_fail :Event(FO_EV_PEER_OCONN_ERR) {
    
    my ($oper,$errno,$errstr,$wid) = @_[ARG0..ARG3];
    log_warnf("%s: %s (%d)", $oper, $errstr, $errno);
    my $peer = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2PEER);
    $peer->reconnect_timer(
        $poe_kernel->delay_set(
            FO_EV_PEER_OCONN_INIT, FOPROTO_RECONNECT_INTERVAL,$peer)
    );
}

sub peer_connect_alarm :Event(FO_EV_PEER_OCONN_ALARM)
{    
    my $peer = $_[ARG0];
    if($peer->is_connected) {
        log_errf("Connect alarm triggered for peer $peer %s", $peer->infostring);
        return;
    } else {
        log_errf("Connection expired for peer %s", $peer->infostring);
        $OBJ->peer_sock_deinit($peer);
    }
}


############# INBOUND CONNECTIONS #############
sub new_connection :Event(FO_EV_ICONN_NEW)
{
    my ($newsock,$wid) = @_[ARG0,ARG3];
    my $wheel = POE::Wheel::ReadWrite->new(
        Handle => $newsock,
        Filter => POE::Filter::JSON::Incr->new(),
        InputEvent => FO_EV_ICONN_INITMSG,
        ErrorEvent => FO_EV_ICONN_ERR,
    );
    
    $Store->store_a(1, FO_RFS_LATTR_IDENT_WAIT, $wheel, StrongValue => 1);
    $Store->store_kt($wheel->ID, FO_RFS_LKEY_WID2WHEEL, $wheel);
}

############## DETERMINE CONNECTION TYPE AND DISPATCH ##############
sub unknown_got_ident :Event(FO_EV_ICONN_INITMSG)
{
    my ($input,$wid) = @_[ARG0..ARG1];
    my $self = $OBJ;
    
    my $wheel = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2WHEEL);
    $Store->dissoc_a(1, FO_RFS_LATTR_IDENT_WAIT, $wheel);
    
    my $msg = $self->parse($input);
    if($msg->ident) {
        my $peer = Failover::Peer->ByID($msg->ident);
        log_infof("New incoming connection from peer %s", $peer->infostring);
        return $OBJ->peer_sock_init($peer, $wheel, $input);
    } else {
        #Client:
        $wheel->event(ErrorEvent => FO_EV_CLIENT_IO_ERR);
        $Store->store_a(1, FO_RFS_LATTR_CLIENT, $wheel, StrongValue => 1);
    }
}

sub peer_io_read :Event(FO_EV_PEER_IO_READ)
{
    my ($input,$wid) = @_[ARG0..ARG1];
    my $peer = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2PEER);
    my $self = $OBJ;
    my $msg = $self->parse($input);
    $poe_kernel->delay_adjust($peer->down_timer, FOPROTO_TIMEO_REPORT);
    $self->peer_got_message($peer, $msg);    
}


####### PEER COMMON INITIALIZATION ########
sub peer_sock_init {
    my ($self,$peer,$handle,$input) = @_;
    return if $peer->is_connected();
    
    if(!$handle->isa('POE::Wheel')) {
        $handle = POE::Wheel::ReadWrite->new(
            Handle => $handle,
            InputEvent => 'blah',
            ErrorEvent => 'blah',
            Filter => POE::Filter::JSON::Incr->new()
        );
    }
    
    $peer->sock($handle);
    $peer->is_connected(1);
    $peer->last_seen(time());
    $peer->remove_timeouts();
    
    $peer->down_timer(
        $poe_kernel->delay_set(FO_EV_PEER_KA_ALARM,
                               FOPROTO_TIMEO_REPORT,$peer)
    );
    
    $handle->event(InputEvent => FO_EV_PEER_IO_READ);
    $handle->event(ErrorEvent => FO_EV_PEER_IO_ERR);
    
    $Store->store_kt($handle->ID, FO_RFS_LKEY_WID2PEER, $peer);
    $self->peer_connected($peer, $input, $handle->ID);    
}

#### COMMON DEINIT ####
sub peer_sock_deinit {
    my ($self,$peer) = @_;
    $peer->sock(undef);
    $peer->is_connected(0);
    $peer->remove_timeouts();
    $Store->purge($peer);
    $self->peer_down($peer);
}


#Error events:
sub peer_keepalive_alarm :Event(FO_EV_PEER_KA_ALARM)
{
    my $peer = $_[ARG0];
    
    log_errf("Peer %s has not reported its status within allotted time",
             $peer->id);
    
    $OBJ->peer_sock_deinit($peer);
}

sub unknown_disconnect :Event(FO_EV_ICONN_ERR)
{
    my $wid = $_[ARG3];
    my $wheel = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2WHEEL);
    log_err("Wheel $wid disconnected before we had a chance to determine its type");
    $Store->dissoc_a(1, FO_RFS_LATTR_IDENT_WAIT, $wheel);
}

sub client_disconnect :Event(FO_EV_CLIENT_IO_ERR)
{
    my $wid = $_[ARG3];
    log_err("Client disconnected");
    $Store->purgeby_kt($wid, FO_RFS_LKEY_WID2WHEEL, $wid);
}

sub peer_io_err :Event(FO_EV_PEER_IO_ERR)
{
    my ($oper,$errnum,$errstr,$wid) = @_[ARG0..ARG3];
    my $peer = $Store->fetch_kt($wid, FO_RFS_LKEY_WID2PEER);
    log_errf("Peer $peer (%s): $oper $errstr ($errnum)", $peer->infostring);
    $OBJ->peer_sock_deinit($peer);
}

sub peer_manage_init {
    my ($self,$lsn_addr) = @_;
    $OBJ = $self;
    POE::Sugar::Attributes->wire_current_session($poe_kernel);
    
    my ($host,$port) = split(/:/, $lsn_addr);
    $port ||= 7979;
    log_info("Will try to listen on $host, port $port");
    
    my $lsn = POE::Wheel::SocketFactory->new(
        BindPort => $port,
        BindAddress => $host,
        Reuse => 1,
        SuccessEvent => FO_EV_ICONN_NEW,
        FailureEvent => FO_EV_SERVER_ERR,
    );
    
    $self->lsn($lsn);    
}

1;