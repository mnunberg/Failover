package Failover::Server::RFS;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT;

use Ref::Store;
our $Store = Ref::Store->new();

use Constant::Generate [qw(
    FO_RFS_LKEY_WID2WHEEL
    FO_RFS_LKEY_WID2PEER
    FO_RFS_LATTR_IDENT_WAIT
    FO_RFS_LATTR_CLIENT
)], -export => 1, -start_at => 1,
    -allvalues => 'fo_rfs_keytypes';

$Store->register_kt($_) for (fo_rfs_keytypes);
1;