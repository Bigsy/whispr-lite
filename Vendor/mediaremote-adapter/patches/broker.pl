#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;
my $path = shift @ARGV or die "Missing framework binary\n";
my $handle = DynaLoader::dl_load_file($path, 0) or die "Cannot load media framework\n";
my $symbol = DynaLoader::dl_find_symbol($handle, 'adapter_broker') or die "Missing broker entry\n";
DynaLoader::dl_install_xsub('main::broker', $symbol);
broker();
