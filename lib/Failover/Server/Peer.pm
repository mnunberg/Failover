package Failover::Server::Peer;
use strict;
use warnings;
use Failover::Protocol;
use Failover::Protocol::ID;
use POE;
use Data::UUID;
use List::MoreUtils;
use List::Util qw(first);

my $Ug = Data::UUID->new();

use base qw(Exporter);

our @EXPORT;

use Constant::Generate {
    FO_PEER_TIMER_DOWN => 'fo_ev_peer_down',
}, -export => 1, -type => 'str';

use Class::XSAccessor {
    constructor => '_real_new',
    accessors => [qw(
        id ipaddr state
        timer_reconnect timer_down
        wheel
        is_inferior is_superior is_self is_master is_connected
        superiors inferiors
        last_seen
        services
    )]
};

my $poe_kernel = 'POE::Kernel';

sub remove_timeouts {
    my $self = shift;
    foreach my $t (qw(reconnect down)) {
        $t = "timer_$t";
        if(defined $self->$t) {
            $poe_kernel->alarm_remove($self->$t);
            $self->$t(undef);
        }
    }
}

sub new {
    my ($cls,%opts) = @_;
    my $o = $cls->_real_new();
    while ( my ($opt,$val) = each %opts ) {
        if(!$o->can($opt)) {
            die("Unknown option '$opt'");
        }
        $o->$opt($val);
    }
    
    $o->neighbors([]);
    $o->inferiors([]);
    $o->superiors([]);
    if(!defined $o->state) {
        $o->state(HA_STATE_UNDEF);
    }
    return $o;
}

my %PeerRegistry;
sub build_peer_list {
    my ($cls,$our_peer,@peers) = @_;
    if(!defined $our_peer->id) {
        warn("We don't have our own ID yet");
        return;
    }
    my @ordered_peers = grep {
        defined $_->id
        && (!$_->id->equals($our_peer->id))
        && ($_->id->flags & FO_IDf_PROVIDER)
    } @peers;
    
    @ordered_peers = sort {
        $a->id->compare($b->id)
    } @peers;
    
    foreach my $peer (@ordered_peers) {
        push @{$our_peer->neighbors}, $peer;
        my $cmpval = $our_peer->id->compare($peer->id);
        
        if($cmpval == 1) {
            push @{$our_peer->inferiors}, $peer;
            $peer->is_inferior(1);
            $peer->is_superior(0);
        } elsif ($cmpval == -1) {
            push @{$our_peer->superiors}, $peer;
            $peer->is_superior(1);
            $peer->is_inferior(0);
        } else {
            warn("Found peer with the same ID as ourselves. This is bad!");
        }
    }
    $PeerRegistry{$_->id->hash} = $_ for @ordered_peers;
}

sub peer_by_addr {
    my ($cls,$addr) = @_;
    first { $_->ipaddr eq $addr } values %PeerRegistry;
}

sub peer_by_id {
    my ($cls,$strid) = @_;
    $PeerRegistry{$strid};
}

1;