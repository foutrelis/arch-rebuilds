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

sub get_provisions {
	state $sth = $dbh->prepare(q{
		SELECT DISTINCT pkgname FROM packages_provision
		JOIN packages ON pkg_id = packages.id
		WHERE name = ?});
	my $pkgname = shift;

	$sth->execute($pkgname);
	return map { $_->[0] } @{$sth->fetchall_arrayref};
}
memoize('get_provisions');

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
		SELECT DISTINCT name FROM deps});
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
			log text NOT NULL DEFAULT '',
			log_size bigint NOT NULL DEFAULT 0,
			builder_id integer REFERENCES builders
		);

		CREATE OR REPLACE VIEW current_build_tasks AS (
			SELECT * FROM build_tasks
			WHERE batch IN (
				SELECT min(batch) FROM build_tasks WHERE status != 'complete'
			)
		);

		CREATE OR REPLACE FUNCTION update_log_size()
		RETURNS TRIGGER AS $$
		BEGIN
			NEW.log_size = octet_length(NEW.log);
			RETURN NEW;
		END;
		$$ language 'plpgsql';

		DROP TRIGGER IF EXISTS update_log_size_trigger ON build_tasks;

		CREATE TRIGGER update_log_size_trigger
			BEFORE UPDATE OF log ON build_tasks
			FOR EACH ROW
			EXECUTE PROCEDURE update_log_size();
	});

	# Avoid messing up existing rebuild list
	my @row = $dbh->selectrow_array(q{SELECT COUNT(*) FROM build_tasks});
	die 'Error: build_tasks table is not empty; aborting' if $row[0];
};

init_db;

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
	push @deps, map { get_provisions $_ } @deps;
	push @{$bases{$base}{deps}}, grep { $_ ne $base } map { get_base($_) } @deps;
}
@{$_->{deps}} = uniq grep { exists $bases{$_} } @{$_->{deps}} for (values %bases);

my $g = Graph::Directed->new;

for my $base (keys %bases) {
	$g->add_vertex($base);
	for my $dep (@{$bases{$base}{deps}}) {
		$g->add_edge($base, $dep);
	}
}

# These are packages we must build first
my @first_batch = qw( gcc gcc-multilib );

add_build_tasks 'pending', 'single', @first_batch;
$g->delete_vertices(@first_batch);

while (1) {
	# Find packages we can build independently and put them a new batch
	if (my @bases = $g->successorless_vertices) {
		$g = $g->delete_vertices(@bases);
		add_build_tasks 'pending', 'single', @bases;
		next;
	}

	# Need to resolve dependency cycles; try doing multiple iterative passes
	# until all packages build and then do a final pass in a following batch
	for my $scc (grep { @$_ > 1 } $g->strongly_connected_components) {
		$g = $g->delete_vertices(@$scc);
		add_build_tasks 'pending', 'multiple', @$scc;
		add_build_tasks 'pending', 'single', @$scc;
	}

	last unless $g->vertices;
}
