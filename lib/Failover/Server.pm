package Failover::Server;
use strict;
use warnings;
use Failover::Server::Events;
 
use Failover::Peer;
use List::Util qw(first);
use Failover::Protocol;
use Failover::Server::RFS;
use Carp qw(cluck confess);

use base qw(Failover::Peer Failover::Protocol POE::Sugar::Attributes);

#Handles proposals. In the future this will be merged into something
#welse:
use base qw(Failover::Server::Proposer);

#Handles peer network connections, on a host level
use base qw(Failover::Server::PeerManager);

use POE::Wheel::SocketFactory;
use POE::Wheel::ReadWrite;
use POE::Kernel;
use POE::Session;
use POE::Filter::JSON::Incr;
use Log::Fu { level => "debug" };
use Data::Dumper;

Log::Fu::Configure(
    Strip => 1
);

use POE;

use Class::XSAccessor {
    constructor => 'new',
    accessors => [qw(
        lsn master proposal_timer
        
    )],
};

our $SelfAddr;
our $SessionName = 'failover-server';

our $OBJ;

my $poe_kernel = 'POE::Kernel';
my $Store = $Failover::Server::RFS::Store;
my $TermTitle;

sub server_error :Event(FO_EV_SERVER_ERR)
{
    my ($oper,$errnum,$errstr,$wid) = @_[ARG0..ARG3];
    log_err("someone set us up the bomb ($oper: $errstr ($errnum)");
    confess("Grrr..");
}

sub _default :Event {
    log_err("Got unknown event ", $_[ARG0]);
}


sub announce :Event(FO_EV_ANNOUNCE)
{
    my $self = $OBJ;
    #log_info("Announcing to neighbors");
    $_->sock->put($self->proto_my_status) for grep { $_->is_connected() }
        @{$self->neighbors};
    $poe_kernel->delay(FO_EV_ANNOUNCE, FOPROTO_ANNOUNCE_INTERVAL);
}

sub set_master_status {
    my $self = shift;
    $self->is_master(1);
    print "\e]2;$SelfAddr (MASTER)\a\n";
    $self->master($self);
    $self->state(HA_STATE_ACTIVE);
    $self->announce();
}

sub set_other_master {
    my ($self,$other_peer) = @_;
    if($self->is_master) {
        die("We're already declared as master!");
    }
    log_infof("New master is %s", $other_peer->infostring);
    $self->master($other_peer);
    $self->state(HA_STATE_STANDBY);
    $self->cancel_proposal();
    $other_peer->state(HA_STATE_ACTIVE);
}

sub wait_all_expiry :Event(FO_EV_SETTLE_ALARM)
{
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
    $OBJ = Failover::Peer->ByAddr($SelfAddr) or die "Can't find ourselves";
    bless $OBJ, __PACKAGE__;
    Failover::Peer->ChoosePeer($OBJ);
    return $OBJ;
}

sub init :Start {
    $OBJ ||= __PACKAGE__->Start();
    my $self = $OBJ;
    
    $self->peer_manage_init($SelfAddr);
    $self->proposer_init();
    
    foreach my $peer (@{$self->neighbors}) {
        $poe_kernel->call($SessionName, FO_EV_PEER_OCONN_INIT, $peer);
    }
    $poe_kernel->delay(FO_EV_SETTLE_ALARM, FOPROTO_TIMEO_SETTLE, $OBJ);
    print "\e]2;$SelfAddr\a\n";
    
    $OBJ->announce();
}

sub peer_connected {
    my ($self,$peer,$input,$wid) = @_;
    $peer->sock->put($OBJ->proto_my_status);
    
    $self->try_propose();
    
    if($input) {
        $poe_kernel->call($SessionName, FO_EV_PEER_IO_READ,
                          $input, $wid);
    }
}

sub peer_down {
    my ($self,$peer) = @_;
    log_infof("De-initializing peer %s", $peer->infostring);
    
    my $old_state = $peer->state();
    $peer->state(HA_STATE_DOWN);
    
    if($old_state == HA_STATE_ACTIVE) {
        $self->master(undef);
        $self->try_propose();
    }
}

#For incoming conncections, whose senders identity is unknown
sub client_input {
    my ($self,$cliwheel,$input) = @_;
    log_infof("Responding to client with information");
    $cliwheel->put($self->proto_respond_to_client());

}

sub peer_got_message {
    my ($self,$peer,$msg) = @_;
    
    if($msg->proposal) {
        log_info("Got proposal..");
        $self->try_proposal_objection($peer);
    }
    
    if($msg->objection) {
        log_warnf("Received objection from %s", $peer->infostring);
        $self->cancel_proposal();
    }
    
    if (my $st = $msg->status) {
        $peer->state($st);
        if($st == HA_STATE_ACTIVE) {
            $self->set_other_master($peer);
        }
    }
}


if(!caller) {
    require Failover::Bootstrap;
    $SelfAddr = $ARGV[0];
    POE::Session->create(inline_states =>
        POE::Sugar::Attributes->inline_states(__PACKAGE__, $SessionName));
    POE::Kernel->run();
}