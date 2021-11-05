#!/usr/bin/env perl 
#===============================================================================
#         FILE: monthly-event-cal.pl
#        USAGE: ./monthly-event-cal.pl [yaml-config-file]
#  DESCRIPTION: monthly event calculator generalized from script for ISC² Silicon Valley Chapter
#       AUTHOR: Ian Kluft
#      CREATED: 03/05/2020
#===============================================================================

use strict;
use warnings;
use utf8;
use Modern::Perl qw(2017);
use autodie;
use English qw(-no_match_vars);
use Carp qw(carp croak confess);
use Date::Calc qw(Today Add_Delta_Days Delta_Days Nth_Weekday_of_Month_Year Month_to_Text);
use Getopt::Long;
use Readonly;
use File::BaseDir qw(config_files data_home);
use DateTime;
use DateTime::Duration;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::TimeZone;
use Data::ICal::DateTime;
use YAML::XS;

#
# configuration constants
#

# configuration file to search for in various configuration paths
Readonly::Scalar my $progbase => "monthly-event-cal";
Readonly::Scalar my $yamlfile => "$progbase.yaml";
Readonly::Scalar my $icalfile => "$progbase.ics";

# default configuration
Readonly::Hash my %defaults => (
	meeting_day => 2, # meeting day of week 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat 7=Sun
	meeting_week => 2, # meeting week of month
	meeting_heading => "Meeting", # table column heading for meeting date
	prep_event_heading => "Newsletter goal", # table column heading for preparatory event date
	deadline_heading => "Submission deadline", # table column heading for submission deadline date
	prep_event_delta => 14, # delta days for preparatory event date (positive number)
	deadline_delta => 17, # delta days for submission deadline date (positive number)
	gen_months => 6, # months of calendar table entries to generate
);

# parameters with special processing instructions: comma = comma-separated
Readonly::Hash my %param_types => (ical => 'comma');

# ICal events to generate
Readonly::Hash my %ical_types => (deadline => 1, prep_event => 2, meeting => 3);

#
# globals
#
my %config = %defaults;

# configuration variable lookup
sub config
{
	my @args = @_;
	if (exists $config{$args[0]}) {
		if ((exists $param_types{$args[0]}) and $param_types{$args[0]} eq 'comma'
			and ref $config{$args[0]} eq "ARRAY")
		{
			# allow multiple args each as comma-separated strings
			return split(/,/x, join(',', @{$config{$args[0]}}));
		}
		return $config{$args[0]};
	}
}

sub debug
{
	my @args = @_;
	if (config('debug') or $ENV{MONTHLY_EVENT_DEBUG}) {
		say STDERR "debug: ".join(' ', @args);
	}
	return;
}

# generate ISO 8601 format date from Date::Calc (array of integers with year, month, day)
sub format_date
{
	my @date = @_;
	return sprintf ("%04d-%02d-%02d", @date);
}

# loop through calendar and generate output
sub process_calendar
{
	my ( $cur_year, $cur_month, $ical_events_list, $ical_select_hash) = @_;
	# loop through next n months
	my $done = 0;
	my @current_ym = ($cur_year, $cur_month);
	my $count = 0;
	my $limit = config('gen_months');
	while ($count < $limit) {
		# generate events
		my $month = Month_to_Text($current_ym[1]);
		my @mtg_date = Nth_Weekday_of_Month_Year(@current_ym, config('meeting_day'), config('meeting_week'));
		my @newsletter_date = Add_Delta_Days(@mtg_date, -config('prep_event_delta'));
		my @newsletter_deadline = Add_Delta_Days(@mtg_date, -config('deadline_delta'));
		if (Delta_Days(Today,@newsletter_date) > 0) {
			say "<tr>";
			say "<td>$month $current_ym[0]</td>";
			say "<td>".format_date(@newsletter_deadline)."</td>";
			say "<td>".format_date(@newsletter_date)."</td>";
			say "<td>".format_date(@mtg_date)."</td>";
			say "</tr>";
			$count++;
		}

		# add ICal event generation
		foreach my $key (sort keys %$ical_select_hash) {
			my $vevent = Data::ICal::Entry::Event->new();
			if ((exists $config{events}{$key}) and ref $config{events}{$key} eq "HASH") {
				my @attrs = %{$config{events}{$key}};
				$vevent->add_properties(
					@attrs
				);
			}
		}

		# advance to next month
		$current_ym[1]++;
		if ($current_ym[1] > 12) {
			$current_ym[1] = 1;
			$current_ym[0]++;
		}
	}

	return;
}

# write output to calendar file
sub write_ical_file
{
	my $ical_events = shift;

	# add events to calendar object
	my $calendar = Data::ICal->new();
	$calendar->add_entries(@$ical_events);

	# open file and write ICal text
	my $ical_out_path = config("ical_out") // data_home($progbase, $icalfile);
	open(my $out_fh, '>', $ical_out_path)
		or croak "failed to open ICal data file for output: $!";
	print $out_fh $calendar->as_string
		or croak "failed to write to ICal data file: $!";
	close $out_fh
		or croak "failed to close ICal data file: $!";
	return;
}

# mainline wrapper function - for catching exceptions
sub main
{
	# If YAML config file exists, use data in it to override configuration.
	# This is lower priority than command line, which is processed next and will override YAML configs.
	# Use FreeDesktop.Org XDG Base Directory Specification to search for config files.
	# https://specifications.freedesktop.org/basedir-spec/latest/
	my @configfiles = config_files($yamlfile);
	if (-f "./$yamlfile") {
		# if YAML file of the right name exists in current directory, consider it last in the search
		# so that configs with the same keys are overridden
		push @configfiles, "./$yamlfile";
	}
	foreach my $configfile (@configfiles) {
		debug "checking $configfile";
		if ( -f $configfile ) {
			debug "reading $configfile";
			my @yamldata = YAML::XS::LoadFile($configfile);
			if (ref $yamldata[0] eq "HASH") {
				foreach my $key (keys %{$yamldata[0]}) {
					$config{$key} = $yamldata[0]{$key};
				}
			}
		}
	}

	# process command line
	GetOptions ( \%config, qw(debug meeting_day:i meeting_week:i meeting_heading:s prep_event_heading:s
		deadline_heading:s prep_event_delta:i deadline_delta:i gen_months:i start_year|year:i start_month|month:i
		ical:s@ ical_out:s))
		or croak "Error in command line arguments";

	# default @start_month to this year and month
	my @start_month = Today; pop @start_month;
	if (exists $config{start_year}) {
		$start_month[0] = $config{start_year};
	}
	if (exists $config{start_month}) {
		$start_month[1] = $config{start_month};
	}

	# process ICal parameters if present
	my @ical_events;
	my %ical_select;
	foreach my $ical_item (config('ical')) {
		next if ((not defined $ical_item) or not $ical_item);
		if ($ical_item eq 'all') {
			foreach my $key (keys %ical_types) {
				$ical_select{$key} = 1;
			}
			last; # skip any other ICal generation parameters since we turned them all on with "all"
		} elsif (exists $ical_types{$ical_item}) {
				$ical_select{$ical_item} = 1;
		} else {
			croak "unrecognized ical event type '$ical_item' specified";
		}
	}

	# table heading
	foreach my $str (
		"<table>",
		"<tr>",
		"<th>Month</th>",
		"<th>".config('deadline_heading')."</th>",
		"<th>".config('prep_event_heading')."</th>",
		"<th>".config('meeting_heading')."</th>",
		"</tr>",
	) {
		say $str;
	}

	# loop through next n months
	process_calendar(@start_month, \@ical_events, \%ical_select);

	# table footer
	say "</table>";

	# write ICal event text to file
	if (@ical_events) {
		write_ical_file(\@ical_events);
	}
	return;
}

# run mainline and catch exceptions
{
	local $EVAL_ERROR = ""; # avoid interference from anything that modifies global $@/$EVAL_ERROR
	do { main(); };

	# catch any exceptions thrown in main routine
	if (defined $EVAL_ERROR) {
        # print exception as a plain string
        say STDERR "$0 failed with exception: $EVAL_ERROR";
        exit 1;
	}
}
exit 0;
