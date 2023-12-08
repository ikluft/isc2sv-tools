# isc2sv-tools

This repository contains software tools written for the [ISC2 Silicon Valley Chapter](http://isc2-siliconvalley-chapter.org/), made available for use or co-development with other ISC2 chapters or similar non-profit organizations.

- *[ical-isc2sv-mtg.pl](ical-isc2sv-mtg.pl)*
  - by Ian Kluft
  - purpose: generates a QR code with an ICal event
  - description: This was made for monthly ISC2 Silicon Valley Chapter meetings. By filling in the command-line arguments, it can generate QR codes for a variety of events.
- *[isc2-zoomcsv2cpe.pl](isc2-zoomcsv2cpe.pl)*
  - by Ian Kluft
  - purpose: processes a Zoom webinar attendee report into CSV data with members' CPE points
  - description: This processes a Zoom webinar attendee report (in Comma Separated Values CSV format) into CSV data with members' earned Continuing Professional Education CPE points for the amount of time Zoom says they attended the meeting. I made this for monthly ISC2 Silicon Valley Chapter meetings. This could be useful to other ISC2 chapters, but not likely for any other purposes.
- *[install-perl-prereqs](install-perl-prereqs)*
  - by Ian Kluft
  - purpose: install Perl module dependencies for running install-perl-prereqs and install-perl-prereqs
  - description: This script was a result of helping another volunteer at ISC2 Silicon Valley Chapter to get the install-perl-prereqs and install-perl-prereqs scripts running. I made them on Fedora Linux and now they needed to run on Ubuntu Linux. This script initially tries to install the distro-provided packages and then sets up remaining dependencies with CPAN.
