#!/usr/bin/env perl
# ABOUTME: Post-deploy smoke tests for Magnet IRC Network
# ABOUTME: Validates live infrastructure connectivity, server linking, and services

use strict;
use warnings;
use Test2::V0;
use IO::Socket::INET;

# Skip all tests unless SMOKE_TEST environment variable is set
# This prevents these tests from running in CI without live infrastructure
unless ($ENV{SMOKE_TEST}) {
    skip_all 'Set SMOKE_TEST=1 to run post-deploy smoke tests against live infrastructure';
}

# Test configuration
my $HUB_HOST = $ENV{IRC_HUB_HOST} // 'magnet-9rl.fly.dev';
my $LEAF_HOST = $ENV{IRC_LEAF_HOST} // 'magnet-irc.fly.dev';
my $IRC_PORT = 6667;
my $TIMEOUT = 10;

# Helper: Connect to IRC and get initial response
sub irc_connect {
    my ($host, $port) = @_;
    $port //= $IRC_PORT;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $TIMEOUT,
    );

    return unless $sock;

    # Set timeout for reads
    $sock->timeout($TIMEOUT);

    # Send minimal IRC handshake
    print $sock "NICK smoketest$$\r\n";
    print $sock "USER smoketest 0 * :Smoke Test\r\n";

    # Read responses until we get 001 (welcome) or timeout
    my @responses;
    my $welcomed = 0;
    my $server_name;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($TIMEOUT);

        while (my $line = <$sock>) {
            $line =~ s/\r?\n$//;
            push @responses, $line;

            # Extract server name from first response
            if ($line =~ /^:(\S+)\s/) {
                $server_name //= $1;
            }

            # Check for welcome message (001)
            if ($line =~ /^:\S+\s+001\s/) {
                $welcomed = 1;
                last;
            }

            # Check for errors
            if ($line =~ /^ERROR\s/) {
                last;
            }
        }

        alarm(0);
    };

    # Send QUIT
    print $sock "QUIT :Smoke test complete\r\n";
    close $sock;

    return {
        welcomed    => $welcomed,
        server_name => $server_name,
        responses   => \@responses,
    };
}

# Helper: Get LINKS from server
sub irc_get_links {
    my ($host, $port) = @_;
    $port //= $IRC_PORT;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => $TIMEOUT,
    );

    return [] unless $sock;

    $sock->timeout($TIMEOUT);

    print $sock "NICK linktest$$\r\n";
    print $sock "USER linktest 0 * :Link Test\r\n";

    my @links;
    my $welcomed = 0;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($TIMEOUT * 2);

        while (my $line = <$sock>) {
            $line =~ s/\r?\n$//;

            # Wait for welcome
            if ($line =~ /^:\S+\s+001\s/) {
                $welcomed = 1;
                print $sock "LINKS\r\n";
            }

            # Collect LINKS responses (364)
            if ($line =~ /^:\S+\s+364\s+\S+\s+(\S+)\s+(\S+)\s+:(\d+)\s+(.*)/) {
                push @links, {
                    server      => $1,
                    linked_to   => $2,
                    hop_count   => $3,
                    description => $4,
                };
            }

            # End of LINKS (365)
            if ($line =~ /^:\S+\s+365\s/) {
                last;
            }
        }

        alarm(0);
    };

    print $sock "QUIT\r\n";
    close $sock;

    return \@links;
}

# Helper: Check if service responds
sub check_service {
    my ($host, $service_nick) = @_;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $host,
        PeerPort => $IRC_PORT,
        Proto    => 'tcp',
        Timeout  => $TIMEOUT,
    );

    return 0 unless $sock;

    $sock->timeout($TIMEOUT);

    print $sock "NICK svctest$$\r\n";
    print $sock "USER svctest 0 * :Service Test\r\n";

    my $service_responded = 0;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($TIMEOUT * 2);

        while (my $line = <$sock>) {
            $line =~ s/\r?\n$//;

            # Wait for welcome
            if ($line =~ /^:\S+\s+001\s/) {
                # Query the service
                print $sock "PRIVMSG $service_nick :HELP\r\n";
            }

            # Check for response from service
            if ($line =~ /^:\Q$service_nick\E!\S+\s+NOTICE\s/i) {
                $service_responded = 1;
                last;
            }
        }

        alarm(0);
    };

    print $sock "QUIT\r\n";
    close $sock;

    return $service_responded;
}

# Test 1: Hub accepts connections
subtest 'Hub accepts IRC connections' => sub {
    my $result = irc_connect($HUB_HOST);

    ok($result, "Connected to hub at $HUB_HOST:$IRC_PORT");

    if ($result) {
        ok($result->{welcomed}, "Received IRC welcome (001) from hub");
        like($result->{server_name}, qr/magnet.*internal/i,
             "Server identifies as magnet network");
    }
};

# Test 2: Leaf accepts connections
subtest 'Leaf accepts IRC connections' => sub {
    my $result = irc_connect($LEAF_HOST);

    ok($result, "Connected to leaf at $LEAF_HOST:$IRC_PORT");

    if ($result) {
        ok($result->{welcomed}, "Received IRC welcome (001) from leaf");
        like($result->{server_name}, qr/magnet.*internal/i,
             "Server identifies as magnet network");
    }
};

# Test 3: Servers are linked
subtest 'Servers are linked' => sub {
    my $links = irc_get_links($HUB_HOST);

    ok(scalar @$links > 0, "Got server links from hub");

    if (@$links) {
        # Check that we have the hub
        my @hub = grep { $_->{server} =~ /magnet-9rl/i } @$links;
        ok(@hub, "Hub (magnet-9rl) is in network");

        # Check that at least one leaf is linked
        my @leaves = grep { $_->{server} =~ /magnet-(ord|ams|sin|syd|gru|sea|lhr|iad)/i } @$links;
        ok(@leaves, "At least one leaf server is linked");

        # Check that Atheme is linked
        my @atheme = grep { $_->{server} =~ /atheme/i } @$links;
        ok(@atheme, "Atheme services is linked");

        # Report what we found
        note("Linked servers:");
        for my $link (@$links) {
            note("  $link->{server} -> $link->{linked_to} (hops: $link->{hop_count})");
        }
    }
};

# Test 4: NickServ responds
subtest 'NickServ responds' => sub {
    my $responds = check_service($HUB_HOST, 'NickServ');
    ok($responds, "NickServ responds to HELP command");
};

# Test 5: ChanServ responds
subtest 'ChanServ responds' => sub {
    my $responds = check_service($HUB_HOST, 'ChanServ');
    ok($responds, "ChanServ responds to HELP command");
};

# Test 6: Client IP preservation (check for non-localhost hostname)
subtest 'Client IP preservation via go-mmproxy' => sub {
    my $sock = IO::Socket::INET->new(
        PeerAddr => $HUB_HOST,
        PeerPort => $IRC_PORT,
        Proto    => 'tcp',
        Timeout  => $TIMEOUT,
    );

    ok($sock, "Connected to hub for IP test");

    if ($sock) {
        $sock->timeout($TIMEOUT);

        print $sock "NICK iptest$$\r\n";
        print $sock "USER iptest 0 * :IP Test\r\n";

        my $hostname;

        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm($TIMEOUT);

            while (my $line = <$sock>) {
                $line =~ s/\r?\n$//;

                # Look for "Found your hostname" notice
                if ($line =~ /Found your hostname[:\s]+(\S+)/i) {
                    $hostname = $1;
                }

                # Or extract from welcome message
                if ($line =~ /^:\S+\s+001\s+\S+\s+:.*?(\S+@\S+)/) {
                    $hostname //= $1;
                    last;
                }

                if ($line =~ /^:\S+\s+001\s/) {
                    last;
                }
            }

            alarm(0);
        };

        print $sock "QUIT\r\n";
        close $sock;

        ok($hostname, "Got hostname from server");

        if ($hostname) {
            # Should NOT be localhost/127.0.0.1 if go-mmproxy is working
            unlike($hostname, qr/^(localhost|127\.0\.0\.1|::1)$/,
                   "Hostname is not localhost (go-mmproxy preserving client IP)");
            note("Detected hostname: $hostname");
        }
    }
};

done_testing;
