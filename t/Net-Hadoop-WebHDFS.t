use strict;
use warnings;

use Test::More;
use Test::Deep;
use File::Temp qw(tmpnam);
use File::Basename;

my $tmpnam = basename tmpnam;

BEGIN {
    use_ok('Net::Hadoop::WebHDFS::LWP');
}
require_ok('Net::Hadoop::WebHDFS::LWP');

my ( $WEBHDFS_HOST, $WEBHDFS_PORT, $WEBHDFS_USER )
    = @ENV{qw(WEBHDFS_HOST WEBHDFS_PORT WEBHDFS_USER)};

SKIP: {
    skip 'WEBHDFS_HOST and WEBHDFS_USER must be defined in environment', 3
        if !$WEBHDFS_USER || !$WEBHDFS_HOST;

    ok( my $client = Net::Hadoop::WebHDFS::LWP->new(
            host        => $WEBHDFS_HOST,
            port        => $WEBHDFS_PORT || 14000,
            username    => $WEBHDFS_USER,
            httpfs_mode => 1,
        )
    );
    ok( $client->create(
            '/tmp/Net-Hadoop-WebHDFS-LWP-test-' . $tmpnam,
            "this is a test",    # content
            permission => '644',
            overwrite  => 'true'
        )
    );
    ok( $client->delete(
            '/tmp/Net-Hadoop-WebHDFS-LWP-test-' . $tmpnam,
        )
    );
}

done_testing;
