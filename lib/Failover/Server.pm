package Failover::Server;
use strict;
use warnings;

use Failover::Peer;
use List::Util qw(first);
use Failover::Protocol;

use base qw(Failover::Peer Failover::Protocol POE::Sugar::Attributes);
use base qw(Failover::Server::Proposer);

use POE::Wheel::SocketFactory;
use POE::Wheel::ReadWrite;
use POE::Kernel;
use POE::Session;
use POE::Filter::JSON::Incr;
use Log::Fu { level => "debug" };
use Data::Dumper;

use Ref::Store;

use POE;

use Class::XSAccessor {
    constructor => 'new',
    accessors => [qw(
        neighbors lsn  master
                  proposal_timer
                  )],
};


our $SelfAddr;
our $SessionName = 'failover-server';

our $OBJ;

my $poe_kernel = 'POE::Kernel';

my $Store = Ref::Store->new();
my $LKEY_WID = 'wheelid';
my $LKEY_WID_TO_PEER = 'wid2peer';
my $LATTR_IDENT_WAIT = 'ident_wait';
my $LATTR_CLIENT = 'client_conn';

$Store->register_kt($LKEY_WID);
$Store->register_kt($LATTR_IDENT_WAIT);
$Store->register_kt($LKEY_WID_TO_PEER);
$Store->register_kt($LATTR_CLIENT);

sub server_error :Event {
    my ($oper,$errnum,$errstr,$wid) = @_[ARG0..ARG3];
    log_err("someone set us up the bomb ($oper: $errstr ($errnum)");
}


sub announce :Event {
    my $self = $OBJ;
    log_info("Announcing to neighbors");
    $_->sock->put($self->proto_my_status) for grep { $_->is_connected() }
        @{$self->neighbors};
    $poe_kernel->delay('announce', FOPROTO_ANNOUNCE_INTERVAL);
}

sub set_master_status {
    my $self = shift;
    $self->is_master(1);
    $self->master($self);
    $self->state(HA_STATE_ACTIVE);
    $self->announce();
}

sub set_other_master {
    my ($self,$other_peer) = @_;
    if($self->is_master) {
        die("We're already declared as master!");
    }
    log_infof("New master is %s", $other_peer->id);
    $self->master($other_peer);
    $self->state(HA_STATE_STANDBY);
    $self->cancel_proposal();
    $other_peer->state(HA_STATE_ACTIVE);
}

sub _default :Event {
    log_err("Got unknown event ", $_[ARG0]);
}

sub wait_all_expiry :Event {
    my $self = $_[ARG0];
    foreach my $peer (@{$self->neighbors}) {
        if(!$peer->is_connected) {
            $peer->state(HA_STATE_DOWN);
        }
    }
    log_info("Waited for all hosts.");
    log_infof("Down hosts:", grep { $_->state == HA_STATE_DOWN } @{$self->neighbors});
    $self->try_propose();
}

sub found_master {
    my ($self,$master_peer) = @_;
    if($self->is_master && $master_peer != $self) {
        die("found different master peer from ourselves");
    }
    $self->is_master(0);
    $self->master($master_peer);
    $self->cancel_proposal();
    
}

sub Start {
    my $cls = shift;
    return $OBJ if $OBJ;
    $OBJ = Failover::Peer->peer_by_addr($SelfAddr) or die "Can't find ourselves";
    bless $OBJ, __PACKAGE__;
    $OBJ->init_mypeer();    
    return $OBJ;
}

sub init :Start {
    my ($host,$port) = split(/:/, $SelfAddr);
    $port ||= 7979;
    log_info("Will try to listen on $host, port $port");
    my $lsn = POE::Wheel::SocketFactory->new(
        BindPort => $port,
        BindAddress => $host,
        Reuse => 1,
        SuccessEvent => 'new_connection',
        FailureEvent => 'server_error',
    );
    $OBJ ||= __PACKAGE__->Start();
    $OBJ->lsn($lsn);
    
    foreach my $peer (@{$OBJ->neighbors}) {
        $poe_kernel->call($SessionName, 'peer_do_connect', $peer);
    }
    $poe_kernel->delay('wait_all_expiry', FOPROTO_TIMEO_SETTLE, $OBJ);
    $OBJ->proposer_init();
    $OBJ->announce();
}

#Called on ECONNREFUSED for a peer
sub peer_do_connect :Event {
    my $peer = $_[ARG0];
    my ($paddr,$pport) = split(/:/, $peer->ipaddr);
    $pport ||= 7979;
    my $conn = POE::Wheel::SocketFactory->new(
        RemoteAddress => $paddr,
        RemotePort => $pport,
        SuccessEvent => 'peer_connect_ok',
        FailureEvent => 'peer_connect_fail'
    );
    
    $peer->sock($conn);
    
    $Store->store($conn->ID, $LKEY_WID, $conn);
    $Store->store_kt($conn->ID, $LKEY_WID_TO_PEER, $peer);
    if(!defined $peer->initial_alarm) {
        log_infof("Setting initial alarm for peer %s. Seconds %d", $peer->id,
                  FOPROTO_TIMEO_IDENT);
        $peer->initial_alarm(
            $poe_kernel->delay_set(
                'peer_connect_alarm', FOPROTO_TIMEO_IDENT,
                $peer)
        );

    }
}

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
        $poe_kernel->delay_set('peer_keepalive_alarm',
                               FOPROTO_TIMEO_REPORT,$peer)
    );
    
    $handle->event(InputEvent => 'peer_io_read');
    $handle->event(ErrorEvent => 'peer_io_err');
    
    $Store->store_kt($handle->ID, $LKEY_WID_TO_PEER, $peer);
    $peer->sock->put($OBJ->proto_my_status);
    $self->try_propose();
    
    if($input) {
        $poe_kernel->call($SessionName, 'peer_io_read', $input, $handle->ID);
    }
}

sub peer_deinit {
    my ($self,$peer) = @_;
    log_infof("De-initializing peer %s", $peer->id);
    
    $peer->is_connected(0);
    my $old_state = $peer->state();
    $peer->state(HA_STATE_DOWN);
    $peer->sock(undef);
    $peer->remove_timeouts();
    
    if($old_state == HA_STATE_ACTIVE) {
        $self->master(undef);
        $self->try_propose();
    }
}

#For incoming conncections, whose senders identity is unknown
sub unknown_got_ident :Event {
    my ($input,$wid) = @_[ARG0..ARG1];
    my $self = $OBJ;
    
    my $wheel = $Store->fetch_kt($wid, $LKEY_WID);
    $Store->dissoc_a(1, $LATTR_IDENT_WAIT, $wheel);
    
    my $msg = $self->parse($input);
    if($msg->ident) {
        my $peer = first { $_->id eq $msg->ident } @{$self->neighbors};
        log_infof("New incoming connection from peer %s", $peer->id);
        return $OBJ->peer_sock_init($peer, $wheel, $input);
    } else {
        #Client:
        log_infof("Responding to client with information");
        $wheel->put($self->proto_respond_to_client());
        $wheel->event(ErrorEvent => 'client_disconnect');
        $Store->store_a(1, $LATTR_CLIENT, $wheel, StrongValue => 1);
    }
}

sub unknown_disconnect :Event {
    my $wid = $_[ARG3];
    my $wheel = $Store->fetch_kt($wid, $LKEY_WID, $wid);
    log_err("Wheel $wid disconnected before we had a chance to determine its type");
    $Store->dissoc_a(1, $LATTR_IDENT_WAIT, $wheel);
}

sub client_disconnect :Event {
    my $wid = $_[ARG3];
    log_err("Client disconnected");
    $Store->purgeby_kt($wid, $LKEY_WID, $wid);
}

sub new_connection :Event {
    my ($newsock,$wid) = @_[ARG0,ARG3];
    my $wheel = POE::Wheel::ReadWrite->new(
        Handle => $newsock,
        Filter => POE::Filter::JSON::Incr->new(),
        InputEvent => 'unknown_got_ident',
        ErrorEvent => 'unknown_disconnect',
    );
    
    $Store->store_a(1, $LATTR_IDENT_WAIT, $wheel, StrongValue => 1);
    $Store->store_kt($wheel->ID, $LKEY_WID, $wheel);
}

sub peer_connect_ok :Event {
    my ($newsock,$wid) = @_[ARG0,ARG3];
    my $peer = $Store->fetch_kt($wid, $LKEY_WID_TO_PEER);
    $OBJ->peer_sock_init($peer, $newsock);
    
    #Send our information
    log_infof("Connected to peer %s", $peer->id);
}

sub peer_connect_alarm :Event {
    my $peer = $_[ARG0];
    if($peer->is_connected) {
        log_errf("Connect alarm triggered for peer $peer %s", $peer->id);
        return;
    } else {
        log_errf("Connection expired for peer %s", $peer->id);
        $OBJ->peer_deinit($peer);
    }
}

sub peer_keepalive_alarm :Event {
    my $peer = $_[ARG0];
    
    log_errf("Peer %s has not reported its status within allotted time",
             $peer->id);
    
    $peer->sock(undef);
    $peer->state(HA_STATE_DOWN);
}

sub peer_connect_fail :Event {
    my ($oper,$errno,$errstr,$wid) = @_[ARG0..ARG3];
    log_warnf("%s: %s (%d)", $oper, $errstr, $errno);
    my $peer = $Store->fetch_kt($wid, $LKEY_WID_TO_PEER);
    $peer->reconnect_timer(
        $poe_kernel->delay_set('peer_do_connect', FOPROTO_RECONNECT_INTERVAL,
                               $peer)
    );
}

sub peer_io_read :Event {
    my ($input,$wid) = @_[ARG0..ARG1];
    my $peer = $Store->fetch_kt($wid, $LKEY_WID_TO_PEER);
    my $self = $OBJ;
    my $msg = $self->parse($input);
    #log_debugf("%s: %s", $peer->id, Dumper($input));
    
    if($msg->proposal) {
        log_info("Got proposal..");
        $self->try_proposal_objection($peer);
    }
    
    if($msg->objection) {
        log_warnf("Received objection from %s", $peer->id);
        $self->cancel_proposal();
    }
    
    if (my $st = $msg->status) {
        $peer->state($st);
        if($st == HA_STATE_ACTIVE) {
            $self->set_other_master($peer);
        }
    }
    
    $poe_kernel->delay_adjust($peer->down_timer, FOPROTO_TIMEO_REPORT);
}

sub peer_io_err :Event {
    my ($oper,$errnum,$errstr,$wid) = @_[ARG0..ARG3];
    my $peer = $Store->fetch_kt($wid, $LKEY_WID_TO_PEER);
    log_errf("Peer $peer (%s): $oper $errstr ($errnum)", $peer->id);
    $OBJ->peer_deinit($peer);
}

if(!caller) {
    $SelfAddr = $ARGV[0];
    POE::Session->create(inline_states =>
        POE::Sugar::Attributes->inline_states(__PACKAGE__, $SessionName));
    POE::Kernel->run();
}