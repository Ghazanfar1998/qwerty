# cruft -- lintian check script -*- perl -*-
#
# based on debhelper check,
# Copyright (C) 1999 Joey Hess
# Copyright (C) 2000 Sean 'Shaleh' Perry
# Copyright (C) 2002 Josip Rodin
# Copyright (C) 2007 Russ Allbery
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, you can find it on the World Wide
# Web at http://www.gnu.org/copyleft/gpl.html, or write to the Free
# Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.

package Lintian::cruft;
use strict;
use warnings;
use autodie;
use v5.10;
use feature qw(switch);

use Cwd;
use File::Find;

# Half of the size used in the "sliding window" for detecting bad
# licenses like GFDL with invariant sections.
# NB: Keep in sync cruft-gfdl-fp-sliding-win/pre_build.
use constant BLOCKSIZE => 4096;

use Lintian::Data;
use Lintian::Relation ();
use Lintian::Tags qw(tag);
use Lintian::Util qw(fail is_ancestor_of normalize_pkg_path);

# All the packages that may provide config.{sub,guess} during the build, used
# to suppress warnings about outdated autotools helper files.  I'm not
# thrilled with having the automake exception as well, but people do depend on
# autoconf and automake and then use autoreconf to update config.guess and
# config.sub, and automake depends on autotools-dev.
our $AUTOTOOLS = Lintian::Relation->new (join (' | ',
    Lintian::Data->new ('cruft/autotools')->all));

our $LIBTOOL = Lintian::Relation->new ('libtool | dh-autoreconf');

# The files that contain error messages from tar, which we'll check and issue
# tags for if they contain something unexpected, and their corresponding tags.
our %ERRORS = ('index-errors'    => 'tar-errors-from-source',
               'unpacked-errors' => 'tar-errors-from-source');

# Directory checks.  These regexes match a directory that shouldn't be in the
# source package and associate it with a tag (minus the leading
# source-contains or diff-contains).  Note that only one of these regexes
# should trigger for any single directory.
my @directory_checks =
    ([ qr,^(.+/)?CVS$,        => 'cvs-control-dir'  ],
     [ qr,^(.+/)?\.svn$,      => 'svn-control-dir'  ],
     [ qr,^(.+/)?\.bzr$,      => 'bzr-control-dir'  ],
     [ qr,^(.+/)?\{arch\}$,   => 'arch-control-dir' ],
     [ qr,^(.+/)?\.arch-ids$, => 'arch-control-dir' ],
     [ qr!^(.+/)?,,.+$!       => 'arch-control-dir' ],
     [ qr,^(.+/)?\.git$,      => 'git-control-dir'  ],
     [ qr,^(.+/)?\.hg$,       => 'hg-control-dir'   ],
     [ qr,^(.+/)?\.be$,       => 'bts-control-dir'  ],
     [ qr,^(.+/)?\.ditrack$,  => 'bts-control-dir'  ],

     # Special case (can only be triggered for diffs)
     [ qr,^(.+/)?\.pc$,       => 'quilt-control-dir'  ],
    );

# File checks.  These regexes match files that shouldn't be in the source
# package and associate them with a tag (minus the leading source-contains or
# diff-contains).  Note that only one of these regexes should trigger for any
# given file.  If the third column is a true value, don't issue this tag
# unless the file is included in the diff; it's too common in source packages
# and not important enough to worry about.
my @file_checks =
    ([ qr,^(.+/)?svn-commit\.(.+\.)?tmp$, => 'svn-commit-file'        ],
     [ qr,^(.+/)?svk-commit.+\.tmp$,      => 'svk-commit-file'        ],
     [ qr,^(.+/)?\.arch-inventory$,       => 'arch-inventory-file'    ],
     [ qr,^(.+/)?\.hgtags$,               => 'hg-tags-file'           ],
     [ qr,^(.+/)?\.\#(.+?)\.\d+(\.\d+)*$, => 'cvs-conflict-copy'      ],
     [ qr,^(.+/)?(.+?)\.(r\d+)$,          => 'svn-conflict-file'      ],
     [ qr,\.(orig|rej)$,                  => 'patch-failure-file',  1 ],
     [ qr,((^|/)\.[^/]+\.swp|~)$,         => 'editor-backup-file',  1 ],
    );

# List of files to check for a LF-only end of line terminator, relative
# to the debian/ source directory
our @EOL_TERMINATORS_FILES = qw(control changelog);

sub run {

my (undef, undef, $info) = @_;

my $droot = $info->debfiles;

if (-e "$droot/files" and not -z "$droot/files") {
    tag 'debian-files-list-in-source';
}

# This doens't really belong here, but there isn't a better place at the
# moment to put this check.
my $version = $info->field('version');
# If the version field is missing, assume it to be a native,
# maintainer upload as it is probably the most likely case.
$version = '0-1' unless defined $version;
if ($info->native) {
    if ($version =~ /-/ and $version !~ /-0\.[^-]+$/) {
        tag 'native-package-with-dash-version';
    }
} else {
    if ($version !~ /-/) {
        tag 'non-native-package-with-native-version';
    }
}

# Check if the package build-depends on autotools-dev, automake, or libtool.
my $atdinbd = $info->relation ('build-depends-all')->implies ($AUTOTOOLS);
my $ltinbd  = $info->relation ('build-depends-all')->implies ($LIBTOOL);

# Create a closure so that we can pass our lexical variables into the find
# wanted function.  We don't want to make them global because we'll then leak
# that data across packages in a large Lintian run.
my %warned;
my $format = $info->field('format');
# Assume the package to be non-native if the field is not present.
# - while 1.0 is more likely in this case, Lintian will probably get
#   better results by checking debfiles/ rather than looking for a diffstat
#   that may not be present.
$format = '3.0 (quilt)' unless defined $format;
if ($format =~ /^\s*2\.0\s*\z/ or $format =~ /^\s*3\.0\s*\(quilt\)/) {
    my $wanted = sub { check_debfiles($info, qr/\Q$droot\E/, \%warned) };
    find($wanted, $droot);
} elsif (not $info->native) {
    check_diffstat($info->diffstat, \%warned);
}
my $uroot = $info->unpacked;
my $abs = Cwd::abs_path ("$uroot/") or fail "abs_path $uroot: $!";
$abs =~ s,/$,,; # remove the trailing slash if any
find_cruft($info, \%warned, $atdinbd, $ltinbd);

for my $file (@EOL_TERMINATORS_FILES) {
    my $path = $info->debfiles($file);
    next if not -f $path or not is_ancestor_of($droot, $path);
    open(my $fd, '<', $path);
    while (my $line = <$fd>) {
        if ($line =~ m{ \r \n \Z}xsm) {
            tag 'control-file-with-CRLF-EOLs', "debian/$file";
            last;
        }
    }
    close($fd);
}

# Report any error messages from tar while unpacking the source package if it
# isn't just tar cruft.
for my $file (keys %ERRORS) {
    my $tag = $ERRORS{$file};
    my $path = $info->lab_data_path ($file);
    if (-s $path) {
        open(my $fd, '<', $path);
        local $_;
        while (<$fd>) {
            chomp;
            s,^(?:[/\w]+/)?tar: ,,;

            # Record size errors are harmless.  Skipping to next header
            # apparently comes from star files.  Ignore all GnuPG noise from
            # not having a valid GnuPG configuration directory.  Also ignore
            # the tar "exiting with failure status" message, since it comes
            # after some other error.
            next if /^Record size =/;
            next if /^Skipping to next header/;
            next if /^gpgv?: /;
            next if /^secmem usage: /;
            next if /^Exiting with failure status due to previous errors/;
            tag $tag, $_;
        }
        close($fd);
    }
}

} # </run>

# -----------------------------------

# Check the diff for problems.  Record any files we warn about in $warned so
# that we don't warn again when checking the full unpacked source.  Takes the
# name of a file containing diffstat output.
sub check_diffstat {
    my ($diffstat, $warned) = @_;
    my $saw_file;
    open(my $fd, '<', $diffstat);
    local $_;
    while (<$fd>) {
        my ($file) = (m,^\s+(.*?)\s+\|,)
            or fail("syntax error in diffstat file: $_");
        $saw_file = 1;

        # Check for CMake cache files.  These embed the source path and hence
        # will cause FTBFS on buildds, so they should never be touched in the
        # diff.
        if ($file =~ m,(?:^|/)CMakeCache.txt\z, and $file !~ m,(?:^|/)debian/,) {
            tag 'diff-contains-cmake-cache-file', $file;
        }

        # For everything else, we only care about diffs that add files.  If
        # the file is being modified, that's not a problem with the diff and
        # we'll catch it later when we check the source.  This regex doesn't
        # catch only file adds, just any diff that doesn't remove lines from a
        # file, but it's a good guess.
        next unless m,\|\s+\d+\s+\++$,;

        # diffstat output contains only files, but we consider the directory
        # checks to trigger if the diff adds any files in those directories.
        my ($directory) = ($file =~ m,^(.*)/[^/]+$,);
        if ($directory and not $warned->{$directory}) {
            for my $rule (@directory_checks) {
                if ($directory =~ /$rule->[0]/) {
                    tag "diff-contains-$rule->[1]", $directory;
                    $warned->{$directory} = 1;
                }
            }
        }

        # Now the simpler file checks.
        for my $rule (@file_checks) {
            if ($file =~ /$rule->[0]/) {
                tag "diff-contains-$rule->[1]", $file;
                $warned->{$file} = 1;
            }
        }

        # Additional special checks only for the diff, not the full source.
        if ($file =~ m@^debian/(?:.+\.)?substvars$@) {
            tag 'diff-contains-substvars', $file;
        }
    }
    close($fd);

    # If there was nothing in the diffstat output, there was nothing in the
    # diff, which is probably a mistake.
    tag 'empty-debian-diff' unless $saw_file;
}

# Check the debian directory for problems.  This is used for Format: 2.0 and
# 3.0 (quilt) packages where there is no Debian diff and hence no diffstat
# output.  Record any files we warn about in $warned so that we don't warn
# again when checking the full unpacked source.
sub check_debfiles {
    my ($info, $droot, $warned) = @_;
    (my $name = $File::Find::name) =~ s,^$droot/,,;

    # Check for unwanted directories and files.  This really duplicates the
    # find_cruft function and we should find a way to combine them.
    if (-d) {
        for my $rule (@directory_checks) {
            if ($name =~ /$rule->[0]/) {
                tag "diff-contains-$rule->[1]", "debian/$name";
                $warned->{"debian/$name"} = 1;
            }
        }
    }
    -f or return;
    for my $rule (@file_checks) {
        if ($name =~ /$rule->[0]/) {
            tag "diff-contains-$rule->[1]", "debian/$name";
            $warned->{"debian/$name"} = 1;
        }
    }

    # Additional special checks only for the diff, not the full source.
    if ($name =~ m@^(?:.+\.)?substvars$@o) {
        tag 'diff-contains-substvars', "debian/$name";
    }
}

# Check each file in the source package for problems.  By the time we get to
# this point, we've already checked the diff and warned about anything added
# there, so we only warn about things that weren't in the diff here.
#
# Report problems with native packages using the "diff-contains" rather than
# "source-contains" tag.  The tag isn't entirely accurate, but it's better
# than creating yet a third set of tags, and this gets the severity right.
sub find_cruft {
    my ($info, $warned, $atdinbd, $ltinbd) = @_;
    my $prefix = ($info->native ? 'diff-contains' : 'source-contains');
    my @worklist;

    push(@worklist, $info->index('')->children); # start with the top-level dirs

  ENTRY:
    while ( my $entry = shift(@worklist) ) {
        my $name = $entry->name;
        my $basename = $entry->basename;
        my $path;
        my $file_info;

        if ($entry->is_dir) {
            # Remove the trailing slash (historically we never included the slash
            # for these tags and there is no particular reason to change that now).
            $name = substr($name, 0, -1);
            $basename = substr($basename, 0, -1);

            # Ignore the .pc directory and its contents, created as part of the
            # unpacking of a 3.0 (quilt) source package.

            # NB: this catches all .pc dirs (regardless of depth).  If you
            # change that, please check we have a
            # "source-contains-quilt-control-dir" tag.
            next if $basename eq '.pc';

            # Ignore files in test suites.  They may be part of the test.
            next if $basename =~ m{ \A t (?: est (?: s (?: et)?+ )?+ )?+ \Z}xsm;

            if (not $warned->{$name}) {
                for my $rule (@directory_checks) {
                    if ($basename =~ /$rule->[0]/) {
                        tag "${prefix}-$rule->[1]", $name;
                        # At most one rule will match
                        last;
                    }
                }
            }

            push(@worklist, $entry->children);
            next ENTRY;
        }
        if ($entry->is_symlink) {
            # An absolute link always escapes the root (of a source
            # package).  For relative links, it escapes the root if we
            # cannot normalize it.
            if ($entry->link =~ m{\A / }xsm or not defined($entry->link_normalized)) {
                tag 'source-contains-unsafe-symlink', $name;
            }
            next ENTRY;
        }
        # we just need normal files for the rest
        next ENTRY unless $entry->is_file;

        $file_info = $info->file_info($name);

        if ($file_info =~ m/\bELF\b/) {
            tag 'source-contains-prebuilt-binary', $name;
        } elsif ($file_info =~ m/\b(?:PE(?:32|64)|(?:MS-DOS|COFF) executable)\b/) {
            tag 'source-contains-prebuilt-windows-binary', $name;
        } elsif ($basename =~ /\bwaf$/) {
            my $path = $info->unpacked($entry);
            my $marker = 0;
            open(my $fd, '<', $path);
            while ( my $line = <$fd> ) {
                next unless $line =~ m/^#/o;
                if ($marker && $line =~ m/^#BZ[h0][0-9]/o) {
                    tag 'source-contains-waf-binary', $name;
                    last;
                }
                $marker = 1 if $line =~ m/^#==>/o;
                # We could probably stop here, but just in case
                $marker = 0 if $line =~ m/^#<==/o;
            }
            close($fd);
        }


        unless ($warned->{$name}) {
            for my $rule (@file_checks) {
                next if ($rule->[2] and not $info->native);
                if ($basename =~ /$rule->[0]/) {
                    tag "${prefix}-$rule->[1]", $name;
                }
            }
        }

        # Tests of autotools files are a special case.  Ignore debian/config.cache
        # as anyone doing that probably knows what they're doing and is using it
        # as part of the build.
        if ($basename =~ m{\A config.(?:cache|log|status) \Z}xsm) {
            if ($entry->dirname ne 'debian') {
                tag 'configure-generated-file-in-source', $name;
            }
        } elsif ($basename =~ m{\A config.(?:guess|sub) \Z}xsm and not $atdinbd) {
            open(my $fd, '<', $info->unpacked($entry));
            while (<$fd>) {
                last if $. > 10; # it's on the 6th line, but be a bit more lenient
                if (/^(?:timestamp|version)='((\d+)-(\d+).*)'$/) {
                    my ($date, $year, $month) = ($1, $2, $3);
                    if ($year < 2004) {
                        tag 'ancient-autotools-helper-file', $name, $date;
                    } elsif (($year < 2012) or ($year == 2012 and $month < 4)) {
                        # config.sub   >= 2012-04-18 (was bumped from 2012-02-10)
                        # config.guess >= 2012-06-10 (was bumped from 2012-02-10)
                        # Flagging anything earlier than 2012-04 as outdated
                        # works, due to the "bumped from" dates.
                        tag 'outdated-autotools-helper-file', $name, $date;
                    }
                }
            }
            close($fd);
        } elsif ($basename eq 'ltconfig' and not $ltinbd) {
            tag 'ancient-libtool', $name;
        } elsif ($basename eq 'ltmain.sh', and not $ltinbd) {
            open(my $fd, '<', $info->unpacked($entry));
            while (<$fd>) {
                if (/^VERSION=[\"\']?(1\.(\d)\.(\d+)(?:-(\d))?)/) {
                    my ($version, $major, $minor, $debian) = ($1, $2, $3, $4);
                    if ($major < 5 or ($major == 5 and $minor < 2)) {
                        tag 'ancient-libtool', $name, $version;
                    } elsif ($minor == 2 and (!$debian || $debian < 2)) {
                        tag 'ancient-libtool', $name, $version;
                    } elsif ($minor < 24) {
                        # not entirely sure whether that would be good idea
#                       tag "outdated-libtool", $name, $version;
                    }
                    last;
                }
            }
            close($fd);
        }

        next ENTRY if $info->is_non_free; # (license issue does not apply to non-free)
        next ENTRY if $basename eq 'debian/changelog'; # (license string in debian/changelog are changelog)

        $path = $info->unpacked($entry);

        # test license problem is source file (only text file)
        next ENTRY unless -T $path;

        open(my $F, '<', $path);
        binmode ($F);

        my @queue = ('', '');
        my %licenseproblemhash = ();

        # we try to read this file in block and use a sliding window
        # for efficiency.  We store two blocks in @queue and the whole
        # string to match in $block. Please emit license tags only once
        # per file
        while (read($F, my $window, BLOCKSIZE)) {
            my $block;
            shift @queue;
            push(@queue, lc($window));
            $block =  join '', @queue;

            if (index($block, '\\') > -1) {
                # Remove formatting commonly added by pod2man
                $block =~ s{ \\ & }{}gxsm;
                $block =~ s{ \\s (?:0|-1) }{}gxsm;
                $block =~ s{ \\ \* \( [LR] \" }{\"}gxsm;
            }

            given ($block) {
                # json evil license
                when (index($_, 'evil') > -1 && m/software \s++ shall \s++
                        be \s++ used \s++ for \s++ good \s*+ ,?+ \s*+
                        not \s++ evil/xsm) {
                    if(!exists $licenseproblemhash{'json-evil'}) {
                         tag 'license-problem-json-evil', $name;
                         $licenseproblemhash{'json-evil'} = 1;
                    }
                    continue;
                }
                # check GFDL block - The ".{0,1024}"-part in the regex
                # will contain the "no invariants etc."  part if
                # it is a good use of the license.  We include it
                # here to ensure that we do not emit a false positive
                # if the "redeeming" part is in the next block.
                #
                # See cruft-gfdl-fp-sliding-win for the test case
                when(index($_, 'license') > -1 && m/gnu (?:\s+|\s*<\/span>\s*|\s*\}\s+)? free \s+
                         documentation \s+ license (?'gfdlsections'.{0,1024})
                         a \s+ copy \s+ of \s+ the \s+ license \s+ is \s+ included/xsm) {
                    if (!exists $licenseproblemhash{'gfdl-invariants'}) {
                        # local space
                        my $s = qr{(?:
                          \s              |  # regular space(s)
                          \@c(?:omment)?  |  # Tex info comment
                          [%\*\"\|\\]     |  # String, C-style comment/javadoc indent, quotes for strings, pipe and antislash in some txt
                          \"\s*,          |  # String array (e.g. "line1",\n"line2")
                          ,\s*\"          |  # String array (e.g. "line1"\n ,"line2"), seen in findutils
                          \\n             |  # Verbatim \n in string array
                          \n[-\+!<>]      |  # diff/patch lines
                          \n\.\\\"        |  # man comments
                          <br\s*/?>       |  # (X)HTML line breaks
                          </?link.*?>     |  # xml link
                          </?a.*?>        |  # a link
                          </?p.*?>        |  # html paragraph
                          \(\*note.*?::\) |  # info file note
                        )}xsmo;
                        # GFDL license, assume it is bad unless it
                        # explicitly states it has no "bad sections".
                        given($+{gfdlsections}) {
                            when(m/no $s* Invariant $s+ Sections? $s* ,?
                                   $s+ (?:with$s+)? (?:the$s+)? no $s+ Front(?:\\?-)?$s*Cover $s+ (?:Texts?)? $s* ,? $s+ (?:and$s+)?
                                       (?:with$s+)? (?:the$s+)? no $s+ Back(?:\\?-)?$s*Cover/xiso) {
                                # no invariant
                            }
                            when(m/no $s+ Invariant $s+ Sections?,?
                                      $s+ (?:no$s+)? Front(?:[\\]?-)? $s+ or
                                      $s+ (?:no$s+)? Back(?:[\\]?-)?$s*Cover $s+ Texts?/xiso) {
                                # no invariant variant (dict-foldoc)
                            }
                            when(m/\A $s* (?: [\,\.;] $s* )? version $s+ \d+(?:\.\d+)? $s+
                                   (?:or $s+ any $s+ later $s+ version $s+)?
                                   published $s+ by $s+ the $s+ Free $s+ Software $s+ Foundation $s*
                                   (?: [,\.;] $s*)?
                                   There $s+ are $s+ no $s+ invariants? $s+ sections?
                                   (?: [,\.;] $s*)? \Z
                                   /xismo) {
                                # no invariant libnss-pgsql version
                            }
                            when(m/\A $s* (?: [\,\.;] $s* )? version $s+ \d+(?:\.\d+)? $s+
                                   (?:or $s+ any $s+ later $s+ version $s+)?
                                   published $s+ by $s+ the $s+ Free $s+ Software $s+ Foundation $s*
                                   (?: [,\.;] $s*)?
                                   without $s+ any $s+ Invariant $s+ Sections $s*
                                   (?: [,\.;] $s*)? \Z
                                   /xismo) {
                                # no invariant parsewiki version
                            }
                            when(m/(?: [,\.;] $s*)? version $s+ \d+(?:\.\d+)? $s+
                                   (?:or $s+ any $s+ later $s+ version $s+)?
                                   published $s+ by $s+ the $s+ Free $s+ Software $s+ Foundation $s*
                                   (?: [,\.;] $s*)?
                                   with $s+ no $s+ invariants? $s+ sections?
                                   (?: [,\.;] $s*)? \Z
                                   /xismo) {
                                # no invariant lilypond version
                            }
                            when(m/with $s+ the $s+ Invariant $s+ Sections $s+ being
                                        $s+ (?:\@var\{|<var>)? LIST $s+ THEIR $s+TITLES (?:\}|<\/var>)? $s* ,?
                                        $s+ with $s+ the $s+ Front(?:[\\]?-)$s*Cover $s+ Texts $s+ being
                                        $s+ (?:\@var\{|<var>)? LIST (?:\}|<\/var>)? $s* ,?
                                        $s+ and $s+ with $s+ the $s+ Back(?:[\\]?-)$s*Cover $s+ Texts $s+ being
                                        $s+ (?:\@var\{|<var>)? LIST (?:\}|<\/var>)?/xiso) {
                                # verbatim text of license is ok
                            }
                            when(m/\A $s* (?: [,\.;] $s*)? version $s+ \d+(?:\.\d+)? $s+
                                   (?:or $s+ any $s+ later $s+ version $s+)?
                                   published $s+ by $s+ the $s+ Free $s+ Software $s+ Foundation $s*
                                   (?: [,\.;] $s*)? \Z
                                   /xismo) {
                                # empty text is ambiguous
                                tag 'license-problem-gfdl-invariants-empty', $name;
                                $licenseproblemhash{'gfdl-invariants'} = 1;
                            }
                            # fix #708957 about FDL entities in template
                            when(m/with $s+ \&FDLInvariantSections;, $s+ with $s+ \&FDLFrontCoverText;,
                                        $s+ and $s+ with $s+ \&FDLBackCoverText;/xiso)
                            {
                                unless($name =~ m/\/customization\/[\w-]+\/entities\/[\w-]+\.docbook$/) {
                                    tag 'license-problem-gfdl-invariants', $name;
                                    $licenseproblemhash{'gfdl-invariants'} = 1;
                                }
                            }
                            # fix a false positive in maintain.texi
                            when(m/\A $s* \. $s*
                                   Following $s+ is $s+ an $s+ example $s+ of $s+ the $s+ license $s+ notice $s+
                                   to $s+ use $s+ after $s+ the $s+ copyright $s+ line\(s\) $s+ using $s+ all $s+ the $s+
                                   features $s+ of $s+ the $s+ GFDL/xismo)
                            {
                                # allow only one text
                                unless($name =~ m/maintain/) {
                                    tag 'license-problem-gfdl-invariants', $name;
                                    $licenseproblemhash{'gfdl-invariants'} = 1;
                                }
                            }
                            default {
                                tag 'license-problem-gfdl-invariants', $name;
                                $licenseproblemhash{'gfdl-invariants'} = 1;
                            }
                        }
                    }
                    continue;
                }
            }
        }
        close($F);
    }
}

1;

# Local Variables:
# indent-tabs-mode: nil
# cperl-indent-level: 4
# End:
# vim: syntax=perl sw=4 sts=4 sr et
