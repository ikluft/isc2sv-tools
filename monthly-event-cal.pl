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
use Date::Calc qw(Today Add_Delta_Days Delta_Days Nth_Weekday_of_Month_Year Month_to_Text);
use Getopt::Long;
use Readonly;
use YAML::XS;

# configuration constants
Readonly::Scalar my $yamlfile => "monthly-event-cal.yaml";
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

# globals
my %config = %defaults;

# configuration variable lookup
sub config
{
	return $config{$_[0]} // '';
}

# generate ISO 8601 format date from Date::Calc (array of integers with year, month, day)
sub format_date
{
	my @date = @_;
	return sprintf ("%04d-%02d-%02d", @date);
}

# if YAML file exists, use data in it to override configuration (lower priority than command line, processed next)
if ( -f $yamlfile ) {
	my @yamldata = YAML::XS::LoadFile($yamlfile);
	if (ref $yamldata[0] eq "HASH") {
		foreach my $key (keys %{$yamldata[0]}) {
			$config{$key} = $yamldata[0]{$key};
		}
	}
}

# process command line
GetOptions ( \%config, qw(meeting_day:i meeting_week:i meeting_heading:s prep_event_heading:s deadline_heading:s
	prep_event_delta:i deadline_delta:i gen_months:i start_year|year:i start_month|month:i))
	or die "Error in command line arguments";

# default @start_month to this year and month
my @start_month = Today; pop @start_month;
if (exists $config{start_year}) {
	$start_month[0] = $config{start_year};
}
if (exists $config{start_month}) {
	$start_month[1] = $config{start_month};
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
my $done = 0;
my @current_ym = @start_month;
my $count = 0;
do {
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

	# advance to next month
	$current_ym[1]++;
	if ($current_ym[1] > 12) {
		$current_ym[1] = 1;
		$current_ym[0]++;
	}
} until $count >= config('gen_months');

# table footer
say "</table>";

