package Failover::Server::Proposer;
use strict;
use warnings;
use Failover::Protocol;
use Failover::Server::Events;

use base qw(POE::Sugar::Attributes);
use POE;
use Log::Fu;

my $poe_kernel = 'POE::Kernel';

sub try_propose {
    my $self = shift;
    my $can_propose = 0;
    if($self->master) {
        return;
    }
    
    if(defined $self->proposal_timer) {
        return;
    }
    
    if(!@{ $self->superiors }) {
        $can_propose = 1;
    } else {
        my @higher_candidates =
            grep { $_->state == HA_STATE_ACTIVE ||
                $_->state == HA_STATE_UNDEF } @{$self->superiors};
        if(!@higher_candidates) {
            $can_propose = 1;
        } else {
            log_debug(
                "Still reachable: ",
                map {
                  sprintf("%s:%s", $_->infostring, foproto_strstate($_->state))
                  } @higher_candidates
                );
        }
    }
    if($can_propose) {
        log_warn("Sending proposal...");
        
        foreach my $peer (grep $_->is_connected, @{$self->neighbors}) {
            $peer->sock->put($self->proto_propose);
        }
        
        $self->proposal_timer(
            $poe_kernel->delay_set(FO_EV_PROPOSAL_ALARM, FOPROTO_PROPOSAL_EXPIRY,
                                   $self)
        );
    } else {
        log_debug("Not sending proposal");
    }
}

sub try_proposal_objection {
    my ($self,$proposer) = @_;
    my $can_respond = 0;
    if($proposer->is_inferior || $self->is_master) {
        $can_respond = 1;
    }
    
    if($can_respond) {
        log_infof("Sending OBJECTION to proposal from peer %s",
                  $proposer->infostring);
        
        $proposer->sock->put($self->proto_propose_objection());
    } else {
        log_infof("Nothing to object to proposal from %s", $proposer->infostring);
        $self->cancel_proposal();
    }
}

sub cancel_proposal {
    my $self = shift;
    if($self->proposal_timer) {
        $poe_kernel->alarm_remove($self->proposal_timer);
        $self->proposal_timer(undef);
    }
}

sub proposal_expiry :Event(FO_EV_PROPOSAL_ALARM)
{
    my $self = $_[ARG0];
    #Nobody rejected our proposal. Assume master.
    log_err("Nobody has responed to our proposal yet. Setting ourselves to master");
    $self->set_master_status();
}

sub proposer_init {
    my $self = shift;
    POE::Sugar::Attributes->wire_current_session($poe_kernel);
}