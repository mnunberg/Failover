package Failover::Peer;
use strict;
use warnings;
use POE::Kernel;
use Failover::Protocol;

use List::DoubleLinked;

use List::MoreUtils;
use List::Util qw(first);
use Log::Fu { level => "debug" };
use Dir::Self;
use File::Slurp qw(read_file);


#No export!
use Constant::Generate [qw(
    LKEY_peer_addr
    LKEY_peer_id
)], -type => 'str', -allvalues => '_rfs_kts';

use Ref::Store;
my $Store = Ref::Store->new();
$Store->register_kt($_) for (_rfs_kts);

my $configfile = __DIR__ . '/peers.conf';

use base qw(Exporter);
our @EXPORT;

use Class::XSAccessor {
    constructor => '_real_new',
    accessors => [qw(
        ipaddr
        id
        pri
        last_seen
        state
        sock
        
        is_master
        is_superior
        is_inferior
        is_connected
        
        reconnect_timer
        down_timer
        initial_alarm
        
    )]
};

sub cmp_peer {
    my ($self,$other) = @_;
    if($self->pri < $other->pri) {
        return 1;
    } elsif ($self->pri > $other->pri) {
        return -1;
    } else {
        return $self->id->compare($other->id);
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

sub infostring {
    my $self = shift;
    sprintf("[ID=%s, IP=%s]", $self->id->encode_str, $self->ipaddr);
}

our @PendingNodes;

my @Neighbors;
my @Superiors;
my @Inferiors;
my $ChosenPeer;


sub superiors {
    \@Superiors;
}

sub inferiors {
    \@Inferiors;
}

sub neighbors {
    [@Inferiors, @Superiors];
}

sub known_peers {
    [@Inferiors, @Superiors, @PendingNodes];
}

sub AddPeer {
    my ($self,$other_peer) = @_;
    if(!$ChosenPeer) {
        die("Cannot add peer with add_peer() without having selected peer");
    }
    if(!$other_peer->id) {
        die("Additional peer is missing ID");
    }
    my $cmpret = $self->cmp_peer($other_peer);
    my $reslist;
    if($cmpret == -1) {
        $other_peer->is_superior(1);
        $reslist = \@Superiors;
    } else {
        $reslist = \@Inferiors;
        $other_peer->is_inferior(1);
    }
    push @$reslist, $other_peer;
}

sub ByAddr {
    my ($cls,$ipaddr) = @_;
    $Store->fetch_kt($ipaddr, LKEY_peer_addr);
}

sub ByID {
    my ($cls,$id) = @_;
    die("ID must be a Failover::Protocol::ID")
        unless(ref $id && $id->isa('Failover::Protocol::ID'));
               
    $Store->fetch_kt($id->hash, LKEY_peer_id);
}

sub ChoosePeer {
    my ($cls,$selected_peer) = @_;
    die "Already chosen peer $ChosenPeer" if defined $ChosenPeer;
    $ChosenPeer = $selected_peer;
    
    while ( my $other = pop @PendingNodes ) {
        next if $other == $selected_peer;
        $selected_peer->AddPeer($other);
    }
    log_warn("Superiors:");
    foreach (@Superiors){
        log_warnf("%s: pri=%d", $_->ipaddr, $_->pri);
    }
    log_warn("Inferiors:");
    foreach (@Inferiors) {
        log_warnf("%s: pri=%d", $_->ipaddr, $_->pri);
    }
}

sub new {
    #warn "Use Get() instead of new()";
    goto &Get;
}

sub Get {
    my ($cls,%options) = @_;
    my ($ipaddr,$id) = @options{qw(ipaddr id)};
    unless (defined $ipaddr && defined $id) {
        die("Cannot create new peer without at least an ID and IP");
    }
    
    unless(ref $id && $id->isa('Failover::Protocol::ID')) {
        die("ID object must be a Failover::Protocol::ID object");
    }
    
    my $existing = $cls->ByAddr($ipaddr);
    if($existing) {
        return $existing;
    } else {
        if(!defined $options{state}){
            $options{state} = HA_STATE_UNDEF;
        }
        if(!defined $options{pri}) {
            $options{pri} = FOPROTO_PRI_DEFAULT;
        }
        my $o = $cls->_real_new(%options);
        $Store->store_kt($id->hash, LKEY_peer_id, $o);
        $Store->store_kt($ipaddr, LKEY_peer_addr, $o);
        return $o;
    }
}


1;