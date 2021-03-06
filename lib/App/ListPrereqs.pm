package App::ListPrereqs;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::Any::IfLOG qw($log);

our %SPEC;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(list_prereqs);

$SPEC{list_prereqs} = {
    v => 1.1,
    summary => 'List prerequisites of a Perl module',
    description => <<'_',

Currently skips prerequisites which are modules already in core (for installed
perl version).

_
    args => {
        module => {
            schema  => ['array*'], # XXX of str*
            summary => 'Perl module(s) to check',
            req     => 1,
            pos     => 0,
            greedy  => 1,
        },
        recursive => {
            schema  => [bool => {default=>0}],
            summary => 'Whether to check recursively',
            cmdline_aliases => { r => {} },
        },
        #cache => {
        #    schema  => [bool => {default=>1}],
        #    summary => 'Whether to cache API results for some time, '.
        #        'for performance',
        #},
        raw => {
            schema  => [bool => {default=>0}],
            summary => 'Return raw result',
        },
        # TODO: arg to set cache root dir
        # TODO: arg to set default cache expire period
    },
};
sub list_prereqs {
    require CHI;
    require MetaCPAN::Client;
    require Module::CoreList;

    my %args = @_;
    # XXX schema
    my $mod = $args{module} or return [400, "Please specify module"];
    my $recursive = $args{recursive};
    #my $do_cache = $args{cache} // 1;
    my $raw = $args{raw};

    # '$cache' is ambiguous between args{cache} and CHI object
    my $chi = CHI->new(driver => "File");

    my $mcpan = MetaCPAN::Client->new;

    my $ce = "24h"; # cache expire period

    my @errs;
    my %mdist; # mentioned dist, for checking circularity
    my %mmod;  # mentioned mod

    $^V =~ /^v(\d+)\.(\d+)\.(\d+)/ or die "Can't parse perl version";
    my $perl_v = $1 + $2/1000 + $3/1000/1000;

    my $do_list;
    $do_list = sub {
        my ($mod, $v, $level) = @_;
        $level //= 0;
        $log->debugf("Listing dependencies for module %s (%s) ...", $mod, $v);

        my @res;

        # if it already looks like a dist, save an API call
        my $dist;
        if ($mod =~ /-/) {
            $dist = $mod;
        } else {
            my $modinfo = $chi->compute(
                "metacpan-mod-$mod", $ce, sub {
                    $log->infof("Querying MetaCPAN for module %s ...", $mod);
                    $mcpan->module($mod);
                });
            $dist = $modinfo->distribution;
        }

        if ($mdist{$dist}++) {
            push @errs, "Circular dependency (dist=$dist)";
            return ();
        }

        my $distinfo = $chi->compute(
            "metacpan-dist-$dist", $ce, sub {
                $log->infof("Querying MetaCPAN for dist %s ...", $dist);
                $mcpan->release($dist);
            });

        for my $dep (@{ $distinfo->dependency }) {
            next unless $dep->{relationship} eq 'requires' &&
                $dep->{phase} eq 'runtime';
            next if $dep->{module} =~ /^(perl)$/;
            next if $mmod{$dep->{module}}++;
            my $v_in_core = Module::CoreList->first_release(
                $dep->{module}, $dep->{version_numified});
            if ($v_in_core && $v_in_core <= $perl_v) {
                $log->debugf("Module %s (%s) is already in core (perl %s), ".
                                 "skipped",
                             $dep->{module}, $dep->{version_numified},
                             $v_in_core);
                next;
            }

            my $res = {
                module=>$dep->{module},
                version=>$dep->{version_numified},
            };
            if ($recursive) {
                $res->{prereqs} = [$do_list->(
                    $res->{module}, $res->{version}, $level+1)];
            }
            if ($raw) {
                push @res, $res;
            } else {
                push @res, join(
                    "",
                    "    " x $level,
                    $res->{module}, " ", ($res->{version} // 0),
                    "\n",
                    join("", @{ $res->{prereqs} // [] }),
                );
            }
        }

        @res;
    };

    my @res;
    for (ref($mod) eq 'ARRAY' ? @$mod : $mod) {
        push @res, $do_list->($_);
    }
    my $res = $raw ? \@res : join("", @res);

    [200, @errs ? "Unsatisfiable dependencies" : "OK", $res,
     {"cmdline.exit_code" => @errs ? 200:0}];
}

1;
#ABSTRACT:

=head1 SYNOPSIS

 # Use via list-prereqs CLI script


=head1 DESCRIPTION

Currently uses MetaCPAN API and by default caches API results for 24 hours.


=head1 SEE ALSO

http://deps.cpantesters.org/

=cut
