#!/usr/bin/env perl

use Mojolicious::Lite;
use Mojo::Util qw(decode);
use DBI;
use FindBin;
use IO::Uncompress::Gunzip qw( gunzip );

open my $fh, "$FindBin::Bin/../builder/version";
chomp(my $expected_builder_version = <$fh>);

app->attr(dbh => sub {
	my $dbh = DBI->connect('dbi:Pg:dbname=arch_rebuilds', '', '', {AutoCommit => 1, RaiseError => 1});
	return $dbh;
});

helper db => sub { shift->app->dbh };

helper rebuild_label => sub {
	my ($self, $base) = @_;
	my %labels = (
		complete => 'label-success',
		inprogress => 'label-primary',
		failed => 'label-danger',
	);

	for (keys %labels) {
		return "label $labels{$_}" if $_ eq $base->{status};
	}
	return 'label label-default';
};

helper rebuild_title => sub {
	my ($self, $base) = @_;

	my $title = $base->{status};
	$title .= " ($base->{name})" if $base->{name} and $base->{status} eq 'inprogress';
	return $title;
};

sub move_commands {
	my ($self, $dest) = @_;
	state $sth = $self->db->prepare(q{
		SELECT DISTINCT base, lower(repos.name) AS repo
		FROM build_tasks
		JOIN packages ON pkgbase = base
		JOIN repos ON repos.id = repo_id
		WHERE repos.testing = false
		AND repos.staging = false});
	my %repo_from_to = (
		testing => {
			core => 'staging testing',
			extra => 'staging testing',
			community => 'community-{staging,testing}',
			multilib => 'multilib-{staging,testing}',
		}, stable => {
			core => 'testing core',
			extra => 'testing extra',
			community => 'community{-testing,}',
			multilib => 'multilib{-testing,}',
		});

	$sth->execute;
	my %moves;
	while (my $row = $sth->fetchrow_hashref) {
		push @{$moves{$row->{repo}}}, $row->{base};
	}

	my @cmds;
	for (sort keys %moves) {
		my $root = $_ =~ /^(core|extra)$/ ? 'packages' : 'community';
		push @cmds, "/$root/db-move $repo_from_to{$dest}{$_} "  .  join ' ', sort @{$moves{$_}};
	}

	return @cmds;
}

sub get_builder {
	my ($self, $token) = @_;
	state $sth = $self->db->prepare(q{
		SELECT * FROM builders WHERE token = ?});

	$sth->execute($token);
	return $sth->fetchrow_hashref;
}

sub get_repos {
	my ($self, $base) = @_;
	state $sth = $self->db->prepare(q{
		SELECT DISTINCT lower(repos.name) FROM packages
		JOIN repos ON repos.id = repo_id
		WHERE pkgbase = ?
		AND repos.testing = false
		AND repos.staging = false});

	$sth->execute($base);
	my @repos = map { $_->[0] } @{$sth->fetchall_arrayref};
	return @repos;
}

post '/fetch' => sub {
	my $self = shift;
	state $sth_fetch = $self->db->prepare(q{
		SELECT base FROM current_build_tasks WHERE status = 'pending'
		ORDER BY random() LIMIT 1});
	state $sth_start = $self->db->prepare(q{
		UPDATE current_build_tasks SET status = 'inprogress', builder_id = ?
		WHERE base = ?});

	if (($self->param('version') // '') ne $expected_builder_version) {
		return $self->render(text => 'BADVER', format => 'txt');
	}

	my $builder = get_builder $self, $self->param('token');
	return $self->render(text => 'BAD AUTH', status => 403, format => 'txt') unless $builder;

	# Kill switch in case something goes terribly wrong
	return $self->render(text => 'NOPKG', format => 'txt') if (-e "$FindBin::Bin/pause");

	$self->db->begin_work;
	$self->db->do(q{LOCK TABLE build_tasks});

	$sth_fetch->execute;
	my ($base) = $sth_fetch->fetchrow_array;
	unless ($base) {
		$self->db->rollback;
		return $self->render(text => 'NOPKG', format => 'txt');
	}

	$sth_start->execute($builder->{id}, $base);
	$self->db->commit;

	my @repos = get_repos($self, $base);
	$self->render(text => "OK $base " . join(' ', get_repos($self, $base)), format => 'txt');
};

post '/update' => sub {
	my $self = shift;
	state $sth = $self->db->prepare(q{
		UPDATE current_build_tasks SET status = ?, log = ?
		WHERE status = 'inprogress' AND builder_id = ? AND base = ?});
	my $base = $self->param('base');
	my $status = $self->param('status');

	my $builder = get_builder $self, $self->param('token');
	return $self->render(text => 'BAD AUTH', status => 403, format => 'txt') unless $builder;

	unless ($base and $status =~ /^(pending|complete|failed)$/) {
		return $self->render(text => 'BAD REQUEST', status => 400, format => 'txt');
	}

	gunzip \$self->param('log'), \my $log;
	$log = decode('UTF-8', $log);

	$self->db->begin_work;
	$self->db->do(q{LOCK TABLE build_tasks});

	my $num = $sth->execute($status, $log, $builder->{id}, $base);
	$self->db->commit;

	$self->render(text => $num == 1 ? 'OK ' . uc $status : 'NOTOK', format => 'txt');
};

get '/log/(#base).log' => sub {
	my $self = shift;
	state $sth = $self->db->prepare(q{SELECT log FROM current_build_tasks WHERE base = ?});
	my $base = $self->param('base');
	my $download = defined $self->param('download');

	$sth->execute($base);
	my $row = $sth->fetchrow_hashref;
	$self->res->headers->content_disposition("attachment; filename=$base.log") if $download;
	$self->render(text => $row->{log}, format => 'txt');
};

get '/retry/#base' => sub {
	my $self = shift;
	state $sth = $self->db->prepare(q{
		UPDATE current_build_tasks SET status = 'pending'
		WHERE status = 'failed' AND base = ?});
	my $base = $self->param('base');

	my $num = $sth->execute($base);
	my $message = $num == 1 ? "Requeued $base" : "Unable to requeue $base";
	my $class = $num == 1 ? 'success' : 'danger';
	$self->flash(alert => {message => $message, class => $class});
	$self->redirect_to('/');
};

get '/move/:dest' => sub {
	my $self = shift;
	my $dest = $self->param('dest');

	my $group_check = <<'EOM';
if [[ $(printf "%s\n" $(id -Gn) | grep -P '^(dev|tu|multilib)$' | wc -l) != 3 ]]; then
	echo 'Need to be in all (dev, tu, multilib) groups to move packages.'
	exit 1
fi
EOM

	$self->render(text => $group_check . join(" &&\n", move_commands $self, $dest), format => 'txt');
};

get '/' => sub {
	my $self = shift;
	state $sth = $self->db->prepare(q{
		WITH status_counts AS (
			SELECT COUNT(*) AS total,
			SUM(CASE WHEN status = 'complete' THEN 1 ELSE 0 END) AS complete,
			SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
			FROM build_tasks
		)
		SELECT total, complete, failed,
		ROUND(100.0 * complete / total, 2) as complete_p,
		ROUND(100.0 * failed / total, 2) as failed_p
		FROM status_counts});
	my $show_all_batches = defined $self->param('all');

	$sth->execute();
	my $progress = $sth->fetchrow_hashref;
	$self->stash(progress => $progress, show_all_batches => $show_all_batches);
	$self->render(template => 'index');
};

app->defaults(layout => 'base');
app->start;
