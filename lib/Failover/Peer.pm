package Failover::Peer;
use strict;
use warnings;
use POE::Kernel;
use Failover::Protocol;

use List::MoreUtils;
use List::Util qw(first);
use Log::Fu { level => "debug" };

use base qw(Exporter);
our @EXPORT;

use Class::XSAccessor {
    constructor => 'new',
    accessors => [qw(
        ipaddr id pri
        last_seen state
        sock
        superiors
        inferiors
        
        is_master
        is_superior
        is_inferior
        is_connected
        
        reconnect_timer
        down_timer
        initial_alarm
    )]
};

my @PeerConfig = (
    ['127.0.0.1:7171', 1],
    ['127.0.0.1:7272', 2],
    ['127.0.0.1:7373', 3]
);

our @PeerList;
foreach (sort { $a->[1] <=> $b->[1] } @PeerConfig) {
    my ($peer,$pri) = @$_;
    my $o = Failover::Peer->new(
        ipaddr => $peer,
        pri => $pri,
        id => $peer,
        state => HA_STATE_UNDEF,
        superiors => [],
        inferiors => []
    );
    push @PeerList, $o;
}

for(my $i = 0; $i <= $#PeerList; $i++) {
    my $o = $PeerList[$i];
    if($i < $#PeerList) {
        $o->inferiors( [ @PeerList[$i+1..$#PeerList] ]);
    }
    if($i > 0) {
        $o->superiors( [ @PeerList[0..$i-1] ]);
    }
}

sub remove_timeouts {
    my $self = shift;
    foreach my $t (qw(reconnect_timer down_timer initial_alarm)) {
        my $aid = $self->$t;
        if(defined $aid) {
            POE::Kernel->alarm_remove($aid);
            $self->$t(undef);
        }
    }
}

sub init_mypeer {
    my $self = shift;
    foreach my $inferior (@{$self->inferiors}) {
        $inferior->is_inferior(1);
    }
    foreach my $superior (@{$self->superiors}) {
        $superior->is_superior(1);
    }
    $self->neighbors([
        grep $_->id ne $self->id, @PeerList
    ]);
}

sub peer_by_addr {
    my ($cls,$addr) = @_;
    return first { $_->ipaddr eq $addr } @PeerList;
}

1;