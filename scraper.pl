#!/usr/bin/env perl
# Copyright 2014 Michal Špaček <tupinek@gmail.com>

# Pragmas.
use strict;
use warnings;

# Modules.
use English;
use Encode qw(decode_utf8 encode_utf8);
use LWP::UserAgent;
use HTML::TreeBuilder;
use Database::DumpTruck;
use POSIX qw(strftime);
use Time::Local;

# Don't buffer.
$OUTPUT_AUTOFLUSH = 1;

# URL of service.
my $URL = 'http://aplikace.policie.cz/statistiky-dopravnich-nehod/Default.aspx';

# 10.2.2009 12:00
my $first_time = 1234263600;

# Time of previous day.
my $time = time - 24 * 60 * 60;

# Open a database handle.
my $dt = Database::DumpTruck->new({
	'dbname' => 'data.sqlite',
#	'debug' => 1,
	'table' => 'data',
});

# Get last date from db.
my $ret_ar = eval {
	$dt->execute('SELECT MAX(Date) FROM data');
};
my $cur_time;
if (! $EVAL_ERROR && @{$ret_ar} && exists $ret_ar->[0]->{'max(date)'}
	&& defined $ret_ar->[0]->{'max(date)'}) {

	my $last_date = $ret_ar->[0]->{'max(date)'};
	my ($last_year, $last_mon, $last_day) = split m/-/ms, $last_date;
	$cur_time = timelocal(0, 0, 12, $last_day, $last_mon - 1,
		$last_year - 1900);
	$cur_time += 24 * 60 * 60;
} else {
	$cur_time = $first_time;
}

# Check for possible new data.
if ($cur_time >= $time) {
	print "No new data.\n";
	exit 0;
}

# Create a user agent object.
my $ua = LWP::UserAgent->new;

# GET for __VIEWSTATE and __EVENTVALIDATION values.
my $get = $ua->get($URL);
my ($viewstate, $eventvalidation);
if ($get->is_success) {
	($viewstate, $eventvalidation) = get_hidden(
		encode_utf8($get->decoded_content));
} else {
	die 'Cannot GET page with hidden variables for POST.';
}

# POST for data.
while (1) {
	post_time($cur_time);
	$cur_time += 24 * 60 * 60;
	if ($cur_time >= $time) {
		last;
	}
}

# Get hidden variables.
sub get_hidden {
	my $data = shift;
	my $tree = HTML::TreeBuilder->new;
	$tree->parse($data);
	my $root = $tree->elementify;
	my @inputs = $root->find_by_tag_name('input');
	my ($viewstate) = map { $_->find_by_attribute('name', '__VIEWSTATE')
		? $_->attr('value') : () } @inputs;
	my ($eventvalidation) = map {
		$_->find_by_attribute('name', '__EVENTVALIDATION')
		? $_->attr('value') : () } @inputs;
	return ($viewstate, $eventvalidation);
}

# Get POST date.
sub get_post_date {
	my $time = shift;
	my (undef, undef, undef, $day, $mon, $year) = localtime($time);
	$year += 1900;
	$mon++;
	return sprintf '%02d.%02d.%04d', $day, $mon, $year;
}

# Get database date.
sub get_db_date {
	my $time = shift;
	return strftime('%Y-%m-%d', localtime($time));
}

# Insert data for date.
sub post_time {
	my $time = shift;
	my $date = get_post_date($time);
	print "Get data for '$date' date: ";
	my $post = $ua->post($URL, {
		'__VIEWSTATE' => $viewstate,
		'__EVENTVALIDATION' => $eventvalidation,
		'ctl00$Application$ddlKraje' => decode_utf8('Česká republika'),
		'ctl00$Application$txtDatum' => $date,
		'ctl00$Application$cmdZobraz' => 'Zobrazit',
	});
	if ($post->is_success) {
		save_data(encode_utf8($post->decoded_content), $time);
	} else {
		print "KO\n";
		die "Cannot POST page for '$date'.";
	}
	return;
}

# Save data to sqlite database.
sub save_data {
	my ($data, $time) = @_;
	my $tree = HTML::TreeBuilder->new;
	$tree->parse($data);
	my $root = $tree->elementify;
	my $table = $root->find_by_attribute('id', 'celacr');
	if (! defined $table) {
		print "No data\n";
		return;
	}
	my @tr = $table->content_list;
	shift @tr;
	shift @tr;
	pop @tr;
	pop @tr;
	foreach my $tr (@tr) {
		my @data;
		my @td = $tr->content_list;
		pop @td;
		foreach my $td (@td) {
			my $text = $td->as_text;
			$text =~ s/\s*$//msg;
			push @data, $text;
		}
		my $db_date = get_db_date($time);
		$dt->insert({
			'Date' => $db_date,
			'Region' => decode_utf8($data[0]),
			'Number_of_accidents' => $data[1],
			'Deaths' => $data[2],
			'Severely_wounded' => $data[3],
			'Slightly_wounded' => $data[4],
			'Damage' => $data[5],
			'Excessive_speed' => $data[6],
			'Giving_priority_in_driving' => $data[7],
			'Improper_overtaking' => $data[8],
			'Wrong_way_driving' => $data[9],
			'Other_cause' => $data[10],
			'Influence_of_alcohol' => $data[11],
		});
	}
	print "OK\n";
	return;
}
