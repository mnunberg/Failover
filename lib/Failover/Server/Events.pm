package Failover::Server::Events;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT;

use Constant::Generate [qw(
    PEER_OCONN_INIT
    PEER_OCONN_OK
    PEER_OCONN_ERR
    PEER_OCONN_ALARM
    
    ICONN_NEW
    ICONN_INITMSG
    ICONN_ERR
    
    PEER_IO_READ
    PEER_IO_ERR
    PEER_KA_ALARM
    
    CLIENT_IO_ERR
    
    SERVER_ERR
    
    ANNOUNCE
    
    SETTLE_ALARM
    PROPOSAL_ALARM
    
)], -type => 'str', -export => 1, -prefix => 'FO_EV_',
    -allvalues => 'fo_ev_names';
    
use Log::Fu;

log_err(join(",", fo_ev_names()));
1;