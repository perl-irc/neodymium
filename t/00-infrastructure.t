#!/usr/bin/env perl
# ABOUTME: Infrastructure validation tests for Magnet IRC Network Fly.io deployment
# ABOUTME: Tests fly.toml configurations, templates, and deployment readiness

use strict;
use warnings;
use Test2::V0;

# Current architecture apps
my %EXPECTED_APPS = (
    'magnet-9rl' => {
        description => 'US Hub IRC server',
        region      => 'ord',
        memory      => '1gb',
        cpus        => 1,
        ports       => [6667, 6697, 7000, 16667, 16697],
    },
    'magnet-irc' => {
        description => 'Anycast leaf IRC servers',
        region      => 'ord',
        memory      => '512mb',
        cpus        => 1,
        ports       => [6667, 6697, 7000, 16667, 16697],
    },
    'magnet-atheme' => {
        description => 'IRC Services (NickServ, ChanServ, etc)',
        region      => 'ord',
        memory      => '512mb',
        cpus        => 1,
        ports       => [6667],  # Atheme connects via flycast
    },
    'magnet-convos' => {
        description => 'Web IRC client',
        region      => 'ord',
        memory      => '512mb',
        cpus        => 1,
        ports       => [3000],
    },
);

# Test 1: Verify fly.toml files exist
subtest 'fly.toml files exist' => sub {
    foreach my $app (sort keys %EXPECTED_APPS) {
        my $fly_toml_path = "servers/$app/fly.toml";
        ok(-f $fly_toml_path, "fly.toml exists for $app ($EXPECTED_APPS{$app}{description})");
    }
};

# Test 2: Validate fly.toml configuration structure
subtest 'fly.toml configuration validity' => sub {
    foreach my $app (sort keys %EXPECTED_APPS) {
        my $fly_toml_path = "servers/$app/fly.toml";
        next unless -f $fly_toml_path;

        open my $fh, '<', $fly_toml_path or die "Can't open $fly_toml_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        like($content, qr/^app\s*=\s*(?:"|')$app(?:"|')/m, "App name matches for $app");
        like($content, qr/^primary_region\s*=\s*(?:"|')$EXPECTED_APPS{$app}->{region}(?:"|')/m,
             "Primary region correct for $app");
        like($content, qr/\[vm\]/m, "VM configuration exists for $app");
    }
};

# Test 3: Validate resource allocation
subtest 'resource allocation' => sub {
    foreach my $app (sort keys %EXPECTED_APPS) {
        my $fly_toml_path = "servers/$app/fly.toml";
        next unless -f $fly_toml_path;

        open my $fh, '<', $fly_toml_path or die "Can't open $fly_toml_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        like($content, qr/memory\s*=\s*"$EXPECTED_APPS{$app}->{memory}"/m,
             "Memory allocation correct for $app");
        like($content, qr/cpus\s*=\s*$EXPECTED_APPS{$app}->{cpus}/m,
             "CPU allocation correct for $app");
    }
};

# Test 4: Validate port configurations
subtest 'port configurations' => sub {
    foreach my $app (sort keys %EXPECTED_APPS) {
        my $fly_toml_path = "servers/$app/fly.toml";
        next unless -f $fly_toml_path;

        open my $fh, '<', $fly_toml_path or die "Can't open $fly_toml_path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        foreach my $port (@{$EXPECTED_APPS{$app}->{ports}}) {
            like($content, qr/port\s*=\s*$port/m,
                 "Port $port configured for $app");
        }
    }
};

# Test 5: Validate required templates exist
subtest 'required templates exist' => sub {
    my @required_templates = (
        'solanum/common.conf.template',
        'solanum/opers.conf.template',
        'solanum/start.sh',
        'solanum/Dockerfile',
        'atheme/atheme.conf.template',
        'atheme/entrypoint.sh',
        'atheme/Dockerfile',
    );

    foreach my $template (@required_templates) {
        ok(-f $template, "Required file exists: $template");
    }
};

# Test 6: Validate server-specific configurations
subtest 'server-specific configurations' => sub {
    my @irc_servers = qw(magnet-9rl magnet-irc);

    foreach my $server (@irc_servers) {
        my $server_conf = "servers/$server/server.conf";
        ok(-f $server_conf, "Server config exists: $server_conf");

        if (-f $server_conf) {
            open my $fh, '<', $server_conf or die "Can't open $server_conf: $!";
            my $content = do { local $/; <$fh> };
            close $fh;

            like($content, qr/serverinfo\s*\{/m, "$server has serverinfo block");
            like($content, qr/class\s*"server"\s*\{/m, "$server has server class");
            like($content, qr/connect\s*"/m, "$server has connect block");
        }
    }
};

# Test 7: Validate go-mmproxy integration in hub config
subtest 'go-mmproxy integration' => sub {
    my $start_sh = 'solanum/start.sh';
    ok(-f $start_sh, "start.sh exists");

    if (-f $start_sh) {
        open my $fh, '<', $start_sh or die "Can't open $start_sh: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        like($content, qr/go-mmproxy/, "start.sh references go-mmproxy");
        like($content, qr/ip rule add/, "start.sh sets up routing rules for mmproxy");
        like($content, qr/PROXY/, "start.sh handles PROXY protocol");
    }
};

# Test 8: Validate Atheme services configuration
subtest 'Atheme services configuration' => sub {
    my $atheme_conf = 'atheme/atheme.conf.template';
    ok(-f $atheme_conf, "Atheme config template exists");

    if (-f $atheme_conf) {
        open my $fh, '<', $atheme_conf or die "Can't open $atheme_conf: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        like($content, qr/loadmodule\s*"nickserv\/main"/, "NickServ module loaded");
        like($content, qr/loadmodule\s*"chanserv\/main"/, "ChanServ module loaded");
        like($content, qr/loadmodule\s*"operserv\/main"/, "OperServ module loaded");
        like($content, qr/uplink\s*"/, "Uplink configuration present");
        like($content, qr/protocol\/solanum/, "Solanum protocol module loaded");
    }
};

# Test 9: Validate hub has connect blocks for leaves
subtest 'hub connect blocks for leaves' => sub {
    my $hub_conf = 'servers/magnet-9rl/server.conf';
    ok(-f $hub_conf, "Hub server config exists");

    if (-f $hub_conf) {
        open my $fh, '<', $hub_conf or die "Can't open $hub_conf: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        # Hub should have connect blocks for services and leaves
        like($content, qr/connect\s*"magnet-atheme/, "Hub has Atheme connect block");
        like($content, qr/connect\s*"magnet-ord/, "Hub has ORD leaf connect block");
        like($content, qr/connect\s*"magnet-ams/, "Hub has AMS leaf connect block");
    }
};

# Test 10: Validate leaf has autoconn to hub
subtest 'leaf autoconn configuration' => sub {
    my $leaf_conf = 'servers/magnet-irc/server.conf';
    ok(-f $leaf_conf, "Leaf server config exists");

    if (-f $leaf_conf) {
        open my $fh, '<', $leaf_conf or die "Can't open $leaf_conf: $!";
        my $content = do { local $/; <$fh> };
        close $fh;

        like($content, qr/connect\s*"magnet-9rl/, "Leaf has hub connect block");
        like($content, qr/autoconn/, "Leaf has autoconn flag for hub");
    }
};

done_testing;
