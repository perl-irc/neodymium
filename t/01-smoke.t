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
# Note: Hub (magnet-9rl) is S2S only - no external client ports
# All client tests go through the leaf, which connects to the hub
my $LEAF_HOST = $ENV{IRC_LEAF_HOST} // 'magnet-irc.fly.dev';
my $IRC_PORT = 6667;
my $TIMEOUT = 20;

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

# Test 1: Leaf accepts connections
subtest 'Leaf accepts IRC connections' => sub {
    my $result = irc_connect($LEAF_HOST);

    ok($result, "Connected to leaf at $LEAF_HOST:$IRC_PORT");

    if ($result) {
        ok($result->{welcomed}, "Received IRC welcome (001) from leaf");
        like($result->{server_name}, qr/magnet.*internal/i,
             "Server identifies as magnet network");
    }
};

# Test 2: Servers are linked
subtest 'Servers are linked' => sub {
    my $links = irc_get_links($LEAF_HOST);

    ok(scalar @$links > 0, "Got server links from leaf");

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

# Test 3: NickServ responds
subtest 'NickServ responds' => sub {
    my $responds = check_service($LEAF_HOST, 'NickServ');
    ok($responds, "NickServ responds to HELP command");
};

# Test 4: ChanServ responds
subtest 'ChanServ responds' => sub {
    my $responds = check_service($LEAF_HOST, 'ChanServ');
    ok($responds, "ChanServ responds to HELP command");
};

# Test 5: Client IP preservation (verify not localhost)
# go-mmproxy spoofs client IPs - if broken, server would see 127.0.0.1
subtest 'Client IP preservation via go-mmproxy' => sub {
    my $sock = IO::Socket::INET->new(
        PeerAddr => $LEAF_HOST,
        PeerPort => $IRC_PORT,
        Proto    => 'tcp',
        Timeout  => $TIMEOUT,
    );

    ok($sock, "Connected to leaf for IP test");

    if ($sock) {
        $sock->timeout($TIMEOUT);

        print $sock "NICK iptest$$\r\n";
        print $sock "USER iptest 0 * :IP Test\r\n";

        my @connection_info;
        my $is_localhost = 0;

        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm($TIMEOUT);

            while (my $line = <$sock>) {
                $line =~ s/\r?\n$//;

                # Collect any notices about IP/hostname detection
                if ($line =~ /hostname|looking up|found your/i) {
                    push @connection_info, $line;
                }

                # Check for localhost indicators (would mean go-mmproxy isn't working)
                if ($line =~ /\b(127\.0\.0\.1|localhost|::1)\b/i) {
                    $is_localhost = 1;
                    push @connection_info, "LOCALHOST DETECTED: $line";
                }

                # Stop after welcome
                if ($line =~ /^:\S+\s+001\s/) {
                    push @connection_info, $line;
                    last;
                }
            }

            alarm(0);
        };

        print $sock "QUIT\r\n";
        close $sock;

        # Report what we found
        for my $info (@connection_info) {
            note("Connection info: $info");
        }

        # The key test: should NOT see localhost if go-mmproxy is working
        ok(!$is_localhost, "Client IP is not localhost (go-mmproxy working)");
    }
};

done_testing;
