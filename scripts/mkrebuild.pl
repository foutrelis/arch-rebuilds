#!/usr/bin/env perl

use 5.10.1;
use strict;
use warnings;
use autodie;

use DBI;
use Memoize;
use Graph::Directed;
use Data::Dumper;

my $dbh = DBI->connect('dbi:Pg:dbname=arch_rebuilds', '', '', {AutoCommit => 1, RaiseError => 1});

sub uniq {
	my %seen;
	return grep { ! $seen{$_}++ } @_;
}

sub get_base {
	state $sth = $dbh->prepare(q{SELECT pkgbase FROM packages WHERE pkgname = ?});
	my $pkgname = shift;

	$sth->execute($pkgname);
	my @row = $sth->fetchrow_array;
	return $row[0] // $pkgname;
}
memoize('get_base');

sub get_deps {
	state $sth = $dbh->prepare(q{
		WITH RECURSIVE deps AS (
				SELECT name FROM packages_depend
				JOIN packages ON packages.id = pkg_id
				WHERE pkgname = ? AND deptype IN ('D', 'M')
			UNION
				SELECT packages_depend.name FROM deps
				JOIN packages ON pkgname = deps.name
				JOIN packages_depend ON pkg_id = packages.id
				WHERE deptype = 'D'
		)
		SELECT name FROM deps});
	my $pkgname = shift;

	$sth->execute($pkgname);
	return map { $_->[0] } @{$sth->fetchall_arrayref};
}

sub init_db {
	$dbh->do(q{
		CREATE TABLE IF NOT EXISTS builders (
			id serial PRIMARY KEY,
			token varchar UNIQUE NOT NULL DEFAULT md5(random()::text) CHECK (token != ''),
			name varchar NOT NULL CHECK (name != '')
		);

		CREATE TABLE IF NOT EXISTS build_tasks (
			id serial PRIMARY KEY,
			batch integer NOT NULL,
			base varchar NOT NULL,
			status varchar NOT NULL DEFAULT 'pending',
			passes varchar NOT NULL DEFAULT 'single',
			log string NOT NULL DEFAULT '',
			builder_id integer REFERENCES builders
		);

		CREATE OR REPLACE VIEW current_build_tasks AS (
			SELECT * FROM build_tasks
			WHERE batch IN (
				SELECT min(batch) FROM build_tasks WHERE status != 'complete'
			)
		);
	});
};

sub add_build_tasks {
	state $batch++;
	state $sth = $dbh->prepare(q{
		INSERT INTO build_tasks (batch, base, status, passes) VALUES (?, ?, ?, ?)});
	my ($status, $passes) = (shift, shift);

	$sth->execute($batch, $_, $status, $passes) for @_;
}

# Read package names from stdin
my @pkgs = map { chomp; $_ } <>;

# Group by package base and calculate dependencies
my %bases = map { get_base($_) => {deps => []} } @pkgs;
for my $pkg (@pkgs) {
	my $base = get_base($pkg);
	my @deps = get_deps($pkg);
	push @{$bases{$base}{deps}}, grep { $_ ne $base } map { get_base($_) } @deps;
}
@{$_->{deps}} = uniq grep { exists $bases{$_} } @{$_->{deps}} for (values %bases);

init_db;

my %done = map { $_ => 1 } qw ( gcc gcc-multilib );
add_build_tasks 'pending', 'single', keys %done;;

RETRY:
while (1) {
	my @pkgs;
	for my $base (keys %bases) {
		next if $done{$base};
		my @deps = grep { ! $done{$_} } @{$bases{$base}{deps}};
		unless (@deps) {
			push @pkgs, $base;
		}
	}
	last unless @pkgs;

	$done{$_} = 1 for @pkgs;
	add_build_tasks 'pending', 'single', @pkgs;
}

my $graph = Graph::Directed->new;

for my $base (keys %bases) {
	next if $done{$base};
	my @deps = grep { ! $done{$_} } @{$bases{$base}{deps}};
	$graph->add_edge($base, $_) for @deps;
}

if (my @pkgs = map { @$_ } grep { scalar @$_ > 1 } $graph->strongly_connected_components) {
	$done{$_} = 1 for @pkgs;
	add_build_tasks 'pending', 'multiple', @pkgs;
	add_build_tasks 'pending', 'single', @pkgs;
	goto RETRY;
}

# There should not be any packages left but check anyway
add_build_tasks 'pending', 'none', grep { ! $done{$_} } keys %bases;
