#!/usr/bin/perl 
#===============================================================================
#         FILE: zoomcsv2cpe.pl
#  DESCRIPTION: convert Zoom webinar attendee report to ISC2 CPE list
#       AUTHOR: Ian Kluft
# ORGANIZATION: ISC2 Silicon Valley Chapter
#      CREATED: 04/14/2021 04:12:54 PM
#  CLI OPTIONS: --max_cpe=integer CPEs (default 2, abbreviated --cpe)
#               --start=scheduled start time
#               --end=scheduled end time
#               --bus_end=end of business actual time (abbrev --biz)
#               --start_grace_period=integer minutes of grace period at start (default 10, abbrev --grace)
#               --meeting_title=title (abbrev --title)
#               --config_file=YAML config file path (abbrev --config)
#               --output=output file path
#
# originally written for ISC2 Silicon Valley Chapter meetings
# latest code at https://github.com/ikluft/isc2sv-tools
# Open Source terms: GNU General Public License v3.0 https://github.com/ikluft/isc2sv-tools/blob/main/LICENSE
#===============================================================================
use strict;
use warnings;
use utf8;
use autodie;
use Modern::Perl qw(2018);
use feature qw(say fc);
use Carp qw(croak);
use Readonly;
use Getopt::Long;
use File::Slurp;
use Date::Calc;
use File::BOM qw(:subs);
use Text::CSV qw(csv);
use YAML;

use Data::Dumper;

# constants
Readonly::Hash my %default_config => (
    max_cpe => 2,   # default 2 CPEs
    start_grace_period => 10, # 10 minute connection grace period at schedule start to qualify for max CPEs
    output => "/dev/stdout",
);
Readonly::Hash my %option_def => (
    "help" => "display these usage instructions",
    "max_cpe|cpe:i" => "maximum CPEs for the event (default ".$default_config{max_cpe}.")",
    "start:s" => "scheduled start time in YYYY-MM-DD HH:MM:SS format",
    "end:s" => "scheduled end time in YYYY-MM-DD HH:MM:SS format",
    "bus_end|biz:s" => "actual end time in YYYY-MM-DD HH:MM:SS format",
    "start_grade_period|grace:i" => "minutes of grace period at start of meeting (default "
        .$default_config{start_grace_period}.")",
    "title|meeting_title:s" => "meeting title",
    "config_file|config:s" => "meeting configuration file",
    "output:s" => "output file (default to standard output)",
    "gen_makefile|gen-makefile" => "generate Makefile instead of CPE report (advanced users with make installed)",
);

# configuration
my %config = %default_config;

# globals
my (%timestamp, %tables, %index, %attendee, %cmd_arg, %member_info_seen);

#
# functions
#

# return debug mode status
sub debug
{
    return 1 if ($config{debug} // 0); # config can be set from YAML or command-line
    return 1 if ($cmd_arg{debug} // 0); # cmd_arg can be set from command-line
    return 1 if ($ENV{DEBUG_CPE} // 0); # environment DEBUG_CPE can enable debugging if needed earlier than CLI/config
    return 0;
}

# debug_print: print debug message, only if in debug mode
sub debug_print
{
    my @args = @_;
    if (debug()) {
        say STDERR "debug: ".(join " ", @args);
    }
    return;
}

# display usage/help info
sub usage
{
    say STDERR "$0 --max_cpe=(integer CPEs) --start=(scheduled start time) --end=(scheduled end time)";
    say STDERR "    --bus_end=(end of business actual time) --start_grace_period=(integer minutes of grace period";
    say STDERR "    --meeting_title=title --config_file=(YAML config file path) --output=(output file path)";
    say STDERR "options";
    foreach my $key (keys %option_def) {
        say STDERR sprintf("--%12s  %s", $key, $option_def{$key});
    }
    return;
}

# generate name-to-index hash from list of strings (table names or column headings)
sub genIndexHash
{
    my $list = shift;
    if (ref $list ne "ARRAY") {
        croak "genIndexHash() requires ARRAY ref parameter, got ".(defined $list ? (ref $list) : "undef");
    }
    my %indexHash;
    for (my $i=0; $i < scalar @$list; $i++) {
        $indexHash{$list->[$i]} = $i;
    }
    return \%indexHash;
}

# parse date & time string into an array of 6 integers (y-m-d-h-m-s) usable by Date::Calc
sub parseDate
{
    my $date_str = shift;
    defined $date_str or croak "parseDate: undefined date string";
    if ($date_str =~ /(\w+)\s+(\d+),\s+(\d{4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)/) {
        my $month = Date::Calc::Decode_Month($1);
        my $day = $2;
        my $year = $3;
        my $hour = $4;
        my $min = $5;
        my $ampm = $6;
        if ($ampm eq "PM") {
            $hour += 12;
        }
        return ($year, $month, $day, $hour, $min, 0);
    } elsif ($date_str =~ /(\w+)\s+(\d+),\s+(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})/) {
        my $month = Date::Calc::Decode_Month($1);
        my $day = $2;
        my $year = $3;
        my $hour = $4;
        my $min = $5;
        my $sec = $6;
        return ($year, $month, $day, $hour, $min, $sec);
    } elsif ($date_str =~ /(\d{4})-(\d{2})-(\d{2})\s(\d{2}):(\d{2}):(\d{2})/) {
        my $year = $1;
        my $month = $2;
        my $day = $3;
        my $hour = $4;
        my $min = $5;
        my $sec = $6;
        return ($year, $month, $day, $hour, $min, $sec);
    }
    my @date = Date::Calc::Parse_Date($date_str);
    if (not @date) {
        croak "failed to parse date";
    }
    return @date;
}

# combine adjacent attendance timeline entries
# if two adjacent timeline entries are non-overlapping but within 60 seconds, combine them into one
# for promotion of an attendee to panelist without disconnection, the difference will be 0-1 seconds
sub combineTimeline
{
    my $timeline = shift;
    my $index = 0;
    if (debug()) {
        foreach my $rec (@$timeline) {
            say STDERR "debug: combineTimeline: ".join(" ", map { $_."=".$rec->{$_} } sort keys %$rec);
        }
    }
    while ($index < scalar @$timeline-1) {
        debug_print "combineTimeline: index=$index size=".(scalar @$timeline);
        my $cur_end = Date::Calc::Date_to_Time(parseDate($timeline->[$index]{'leave time'}));
        my $next_start = Date::Calc::Date_to_Time(parseDate($timeline->[$index+1]{'join time'}));
        if ($cur_end <= $next_start and $next_start - $cur_end < 60) {
            # endpoints within a minute so merge the timeline entries
            $timeline->[$index]{type} = $timeline->[$index]{type}.'/'.$timeline->[$index+1]{type};
            $timeline->[$index]{'leave time'} = $timeline->[$index+1]{'leave time'};
            $timeline->[$index]{'time in session (minutes)'} += $timeline->[$index+1]{'time in session (minutes)'};
            splice @$timeline, $index+1,1; # delete the second record now merged into the first
        } else {
            $index++;
        }
    }
    return;
}

# compute CPEs from attendee timeline data
sub computeCPE
{
    my $attendee = shift;

    my $minutes = 0.0;
    my $prev_type;
    combineTimeline($attendee->{timeline});
    foreach my $timeline_rec (@{$attendee->{timeline}}) {
        # compute minutes of attendance for this timeline record
        # shirt-circuit out of the loop with max CPEs if attendance spans start to end of business
        my @join_time = parseDate($timeline_rec->{'join time'});
        my @leave_time = parseDate($timeline_rec->{'leave time'});
        my $at_start = (Date::Calc::Date_to_Time(@{$timestamp{bus_start}})) >= Date::Calc::Date_to_Time(@join_time);
        my $at_end = Date::Calc::Date_to_Time(@{$timestamp{bus_end}}) <= Date::Calc::Date_to_Time(@leave_time);
        if ($at_start and $at_end) {
            # return max CPEs because one attendance record spans entire meeting from start to end of business
            return $config{max_cpe};
        }
        if ($at_start and not $at_end) {
            $minutes += (Date::Calc::Date_to_Time(@leave_time) - Date::Calc::Date_to_Time(@{$timestamp{start}}))/60.0;
        } elsif (not $at_start and $at_end) {
            $minutes = (Date::Calc::Date_to_Time(@{$timestamp{end}}) - Date::Calc::Date_to_Time(@join_time))/60.0;
        } else { # not present at start or end: use total minutes from join to leave for CPEs
            $minutes += (Date::Calc::Date_to_Time(@leave_time) - Date::Calc::Date_to_Time(@join_time))/60.0;
        }
        $prev_type = $timeline_rec->{type};
    }
    $attendee->{cpe_minutes} = sprintf("%6.3f", $minutes);
    my $cpe = int($minutes/60.0*4+.45)/4.0; # round to the nearest quarter CPE point
    if ($cpe > $config{max_cpe}) {
        $cpe = $config{max_cpe};
    }
    return $cpe;
}

# fetch data from a table by row & column
sub tableFetch
{
    my $args = shift;
    (ref $args eq "HASH")
        or croak "tableFetch() HASH argument required";
    my %missing;
    foreach my $field (qw(table row col)) {
        if (not exists $args->{$field}) {
            $missing{$field} = 1;
        }
    }
    if (%missing) {
        croak "tableFetch() missing parameters: ".(join " ", sort keys %missing);
    }
    my ($table, $row, $col) = ($args->{table}, $args->{row}, $args->{col});
    if (not exists $tables{$table}) {
        croak "tableFetch() no such table $table - defined tables: ".(join ", ", sort keys %tables);
    }
    if (not exists $index{$table}) {
        croak "tableFetch() no index for table $table";
    }
    if (not exists $index{$table}{$col}) {
        croak "tableFetch() no index for $col in table $table";
    }
    if ($row < 0 or $row >= $tables{$table}{count}) {
        croak "tableFetch() no row $row in table $table, max=".($tables{$table}{count}-1);
    }
    return $tables{$table}{data}[$row][$index{$table}{$col}];
}

# read an attendance report file
# this can be used for the CPE report
# alternatively it can read past months' attendance looking for names & ISC2 cert numbers to match with an email
sub read_attendance_report
{
    my $csv_file = shift;

    open_bom(my $fh, $csv_file, ":utf8"); # use File::BOM::open_bom because Zoom's CSV report is UTF8 with Byte Order Mark
    my @lines;
    while (<$fh>) {
        chomp; # remove newlines
        push @lines, $_;
    }
    close $fh;

    #
    # 1st pass: Divide separate Zoom reports into their own CSV tables.
    #

    # CSV libraries can't process multiple CSV tables concatenated into one file like Zoom makes.
    my $table_title = "none";
    my @titles;
    my %csv_tables;
    while (my $line = shift @lines) {
        if ($line =~ /^([^,]+),$/) {
            $table_title = fc $1;
            push @titles, $table_title;
            next;
        }
        if ($line =~ /^Report Generated:,"([^"]*)"$/) {
                $timestamp{generated} = [parseDate($1)];
                next;
        }
        if (not exists $csv_tables{$table_title}) {
            $csv_tables{$table_title} = [];
        }
        push @{$csv_tables{$table_title}}, $line;
    }

    # debug: print names and sizes of tables
    if (debug()) {
        foreach my $table (sort keys %csv_tables) {
            say $table.": ".scalar(@{$csv_tables{$table}});
        }
    }

    #
    # 2nd pass: process CSV text tables into array-of-arrays structure
    #
    my %report;
    foreach my $table (sort keys %csv_tables) {
        $report{$table} = {};
        $report{$table}{data} = [];
        my $csv = Text::CSV->new({binary => 1, blank_is_undef => 1, empty_is_undef => 1, decode_utf8 => 1,
            allow_loose_quotes => 1, allow_loose_escapes => 1});
        if (not defined $csv) {
            croak "Text::CSV initialization failed: ".Text::CSV->error_diag();
        }
        $report{$table}{count} = -1; # start count from -1 so the header won't be included
        foreach my $csv_line (@{$csv_tables{$table}}) {
            $csv->parse($csv_line);
            if ($report{$table}{count} == -1) {
                $csv->column_names(map {fc $_} ($csv->fields()));
                $report{$table}{columns} = [$csv->column_names()];
            } else {
                push @{$report{$table}{data}}, [$csv->fields()];
            }
            $report{$table}{count}++;
        }
    }

    # debug: print data from 2nd pass
    debug_print Dumper(\%report);

    # return results
    return {report => \%report, titles => \@titles};
}

#
# mainline
#

# read command line arguments
GetOptions( \%cmd_arg, keys %option_def)
    or croak "command line argument processing failed";

# display usage/help if requested
if ($cmd_arg{help} // 0) {
    usage();
    exit 0;
}

# if --gen-makefile was specified, stop processing and generate a makefile instead
if ($cmd_arg{gen_makefile} // 0) {
    # find files
    opendir(my $dh, ".") || die "Can't opendir current directory: $!";
    my @file_list = readdir($dh);
    closedir $dh;
    my @attendee_report = grep { /^[0-9]+_Attendee_Report\.csv$/ && -f "$_" } @file_list;
    my @config_files = sort grep { /^cpe-config-[0-9]{4}-[0-9]{2}\.yaml$/ && -f "$_" } @file_list;

    # check required files exist
    if (not @attendee_report) {
        croak "attendee report not found: make sure it's named *_Attendee_Report.csv";
    }
    if (scalar @attendee_report > 1) {
        croak "more than one attendee report file found. Move different months' reports to different subdirectories.";
    }
    if (not @config_files) {
        croak "Config file not found: make sure  it's named cpe-config-yyyy-mm.yaml";
    }

    # find year and month from config file name
    $config_files[0] =~ qr/-([0-9]{4})-([0-9]{2})\./;
    my ($year, $month) = ($1, sprintf("%02d", $2));
    my $outfile = "cpe-report-2021-11.csv";

    # generate Makefile
    my $tab = chr(9);
    open(my $fh, ">", "Makefile")
        or croak "can't open Makefile for writing: $!";
    say $fh "CPEPROG := \$(shell which isc2-zoomcsv2cpe.pl)";
    say $fh "cpe-report-$year-$month.csv: ".$config_files[0]." ".$attendee_report[0]." \$(CPEPROG)";
    say $fh $tab."\$(CPEPROG) --config=".$config_files[0]." --output=cpe-report-$year-$month.csv ".$attendee_report[0];
    close $fh;
    
    exit 0;
}

# read YAML configuration
# YAML configuration can set same options as the command line
# It's also the way to set CPEs for meeting hosts & speakers who aren't properly listed in the Zoom attendee report
if (exists $cmd_arg{config_file} and defined $cmd_arg{config_file}) {
    if (not -f $cmd_arg{config_file}) {
        croak "file ".$cmd_arg{config_file}." does not exist";
    }
    my $data = YAML::LoadFile($cmd_arg{config_file});
    debug_print "YAML data -> ".Dumper($data);

    if (ref $data eq "HASH") {
        # copy base configuration from YAML to config
        if (exists $data->{config} and ref $data->{config} eq "HASH") {
            foreach my $key (keys %{$data->{config}}) {
                $config{$key} = $data->{config}{$key};
            }
        }

        # copy attendee data (hosts/speakers not documented by Zoom attendee report) from YAML to attendee list
        if (exists $data->{attendee} and ref $data->{attendee} eq "HASH") {
            foreach my $key (keys %{$data->{attendee}}) {
                $attendee{$key} = $data->{attendee}{$key};
            }
        }
    }
}

# apply command-line arguments after YAML configuration so they can override it
foreach my $key (keys %cmd_arg) {
    $config{$key} = $cmd_arg{$key};
}

# read CSV text
my $csv_file = shift @ARGV;
if (not $csv_file) {
    foreach my $stdin_path (qw(/proc/self/fd/0 /dev/fd/0)) {
        if (-e $stdin_path) {
            $csv_file = $stdin_path; # use STDIN
            last;
        }
    }
    if (not $csv_file) {
        croak "input file not specified and couldn't find stdin path on this system to use as default";
    }
}
if (not -e $csv_file) {
    croak "file $csv_file does not exist";
}
my $report_ref = read_attendance_report($csv_file);
%tables = %{$report_ref->{report}};
my @table_titles = @{$report_ref->{titles}};

#
# 3rd pass: tally user attendance
#

#
# make indices for tables and columns
#
#$index{tables} = genIndexHash(\@table_titles);
foreach my $table (@table_titles) {
    $index{$table} = genIndexHash($tables{$table}{columns});
}
#say Dumper(\%index);

#
# determine meeting start & end timestamps
# stream_start: start of video stream, collected from webinar report header
# stream_end: end of video stream, collected from webinar report header
# start: scheduled start time
# end: scheduled end time, defaults to max_cpe hours after scheduled start time
# bus_start: start of business is scheduled start time + connection grace period (default 10 minutes)
# bus_end: business end time, defaults to meeting end time
#
my $actual_start = tableFetch({table => 'attendee report', row => 0, col => 'actual start time'});
my $duration = tableFetch({table => 'attendee report', row => 0, col => 'actual duration (minutes)'});
$timestamp{stream_start} = [parseDate($actual_start)];
$timestamp{stream_end} = [Date::Calc::Add_Delta_DHMS(parseDate($actual_start), 0, 0, $duration, 0)];
if (exists $config{start} and defined $config{start}) {
    $timestamp{start} = [parseDate($config{start})];
} else {
    # start time defaults to stream start, highly recommended to use --start parameter to set scheduled start time
    $timestamp{start} = $timestamp{stream_start};
}
$timestamp{bus_start} = [Date::Calc::Add_Delta_DHMS(@{$timestamp{start}}, 0, 0, $config{start_grace_period}, 0)];
if (exists $config{end} and defined $config{end}) {
    $timestamp{end} = [parseDate($config{end})];
} else {
    # end time defaults to start time + max_cpe hours
    $timestamp{end} = [Date::Calc::Add_Delta_DHMS(@{$timestamp{start}}, 0, $config{max_cpe}, 0, 0)];
}
if (exists $config{bus_end} and defined $config{bus_end}) {
    $timestamp{bus_end} = [parseDate($config{bus_end})];
} else {
    # end of business detaults to end of meeting, highly recommended to use --bix parameter to set end of business time
    $timestamp{bus_end} = $timestamp{end};
}
if (debug()) {
    foreach my $rec (keys %timestamp) {
        say STDERR "debug: timestamp $rec: ".join("-", @{$timestamp{$rec}});
    }
}

# assemble per-user attendance data
foreach my $table ('host details', 'attendee details', 'panelist details') {
    my $type;
    if ($table =~ /^(\w+) details/) {
        $type = $1;
    } else {
        $type = $table;
    }
    foreach my $record (@{$tables{$table}{data}}) {
        if ((not exists $record->[$index{$table}{attended}]) or $record->[$index{$table}{attended}] eq "No") {
            next;
        }
        my $email = $record->[$index{$table}{email}];
        defined $email or next;

        # create new attendee record if it doesn't already exist
        # multiple records per attendee may occur for disconnect/reconnect or promotion to panelist
        if (not exists $attendee{$email}) {
            $attendee{$email} = {};
            $attendee{$email}{timeline} = [];
            foreach my $field ('first name', 'last name')
            {
                if ((exists $index{$table}{$field})
                    and (exists $record->[$index{$table}{$field}]))
                {
                    if (not exists $attendee{$email}{$field}) {
                        $attendee{$email}{$field} = $record->[$index{$table}{$field}];
                    }
                }
            }

            # rename isc2 field from survey form
            # TODO: allow recognition of various survey field names for the isc2 certification number
            my $isc2field = "(isc)2 certification:";
            if ((exists $index{$table}{$isc2field})
                and (exists $record->[$index{$table}{$isc2field}]))
            {
                if (not exists $attendee{$email}{isc2}) {
                    $attendee{$email}{isc2} = $record->[$index{$table}{$isc2field}];
                }
            }
        }

        # add an attendee timeline record for the attendance data
        my $timeline = {type => $type};
        foreach my $field ('join time', 'leave time', 'time in session (minutes)') {
            $timeline->{$field} = $record->[$index{$table}{$field}];
        }
        push @{$attendee{$email}{timeline}}, $timeline;
    }
}

#
# compute attendee CPEs and generate CSV (spreadsheet) output CPE data for ISC2
#
{
    ## no critic (InputOutput::RequireBriefOpen)

    # open CSV output filehandle
    open my $out_fh, ">", $config{output}
        or croak "failed to open ".$config{output}." for writing: $!";
    my $csv = Text::CSV->new ({ binary => 1, auto_diag => 1 });
    $csv->say($out_fh,
        ["(ISC)2 Member #", "Member First Name", "Member Last Name", "Title of Meeting", "# CPEs",
        "Date of Activity", "CPE qualifying minutes"]);

    # loop through attendee records: compute CPEs and output CSV CPE data for ISC2
    foreach my $akey (sort {$attendee{$a}{'last name'} cmp $attendee{$b}{'last name'}} keys %attendee) {
        my $record = $attendee{$akey};
        if (not exists $record->{cpe}) {
            my $cpe = computeCPE($attendee{$akey});
            next if not defined $cpe;
            if ($cpe >= 0) {
                $record->{cpe} = $cpe;
            }
        }

        # if ISC2 member certificate number is available, generate CSV for ISC2
        if (exists $record->{isc2} and $record->{isc2} =~ qr/\d+/) {
            # filter out extraneous text as long as the text includes an ISC2 cert name and a number is present
            my $isc2num = $record->{isc2};
            if ($isc2num =~ qr/cissp|csslp|sscp|ccsp|cap|hcispp/i) {
                $isc2num =~ s/\D+//g;
            }
            $csv->say ($out_fh,
                [$isc2num, $record->{'first name'}, $record->{'last name'},
                $config{title}, $record->{cpe},
                sprintf("%02d/%02d/%04d", $timestamp{start}[1], $timestamp{start}[2], $timestamp{start}[0]),
                $record->{cpe_minutes}]);
        } else {
            say STDERR "skipping ".$record->{'last name'}.", ".$record->{'first name'}.": no ISC2 number data";
        }
    }
    close $out_fh
        or croak "failed to close ".$config{output}.": $!";
    debug_print "attendee data -> ".Dumper(\%attendee);
}
