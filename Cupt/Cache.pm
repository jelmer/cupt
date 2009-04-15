package Cupt::Cache;

=head1 NAME

Cupt::Cache - store info about available packages

=cut

use 5.10.0;
use strict;
use warnings;

use Memoize;
memoize('_verify_signature');

use Cupt::Core;
use Cupt::Cache::Pkg;
use Cupt::Cache::BinaryVersion;
use Cupt::Cache::SourceVersion;
use Cupt::System::State;

=begin internal

=head2 can_provide

{ I<virtual_package> => [ I<package_name>... ] }

For each I<virtual_package> this field contains the list of I<package_name>s
that B<can> provide given I<virtual_package>. Depending of package versions,
some versions of the some of <package_name>s may provide and may not provide
given I<virtual_package>. This field exists solely for
I<get_satisfying_versions> subroutine for rapid lookup.

=end internal

=cut

use fields qw(_source_packages _binary_packages _config _pin_settings _system_state
		_can_provide _extended_info);

=head1 FLAGS

=head2 o_memoize

This flag determines whether it worth trade space for time in time-consuming
functions. On by default. By now, it affects
L</get_satisfying_versions> and L</get_sorted_pinned_versions>
methods. If it's on, it stores references, so B<don't> modify results of these
functions, use them in read-only mode. It it's on, these functions are not
thread-safe.

=cut

our $o_memoize = 1;

=head1 METHODS

=head2 new

creates a new Cupt::Cache object

Parameters:

I<config> - reference to L<Cupt::Config|Cupt::Config>

Next params are treated as hash-style param list:

'-source': read Sources

'-binary': read Packages

'-installed': read dpkg status file

Example:

  my $cache = new Cupt::Cache($config, '-source' => 0, '-binary' => 1);

=cut

sub new {
	my $class = shift;
	my $self = fields::new($class);

	$self->{_config} = shift;
	$self->{_pin_settings} = [];
	$self->{_source_packages} = {};
	$self->{_binary_packages} = {};

	my $ref_index_entries;
	eval {
		$ref_index_entries = $self->_parse_sources_lists();
	};
	if (mycatch()) {
		myerr("error while parsing sources list");
		myredie();
	}

	# determining which parts of cache we wish to build
	my %build_config = (
		'-source' => 1,
		'-binary' => 1,
		'-installed' => 1,
		@_ # applying passed parameters
	);

	if ($build_config{'-installed'}) {
		# read system settings
		$self->{_system_state} = new Cupt::System::State($self->{_config}, $self);
	}

	my @index_files;
	foreach my $ref_index_entry (@$ref_index_entries) {
		my $index_file_to_parse = $self->_path_of_source_list($ref_index_entry);
		my $source_type = $ref_index_entry->{'type'};
		# don't parse unneeded indexes
		if (($source_type eq 'deb' && $build_config{'-binary'}) ||
			($source_type eq 'deb-src' && $build_config{'-source'}))
		{
			eval {
				my $base_uri = $ref_index_entry->{'uri'};
				my $ref_release_info = $self->_get_release_info($self->_path_of_release_list($ref_index_entry));
				$ref_release_info->{component} = $ref_index_entry->{'component'};
				$self->_process_index_file($index_file_to_parse, \$base_uri, $source_type, $ref_release_info);
				push @index_files, $index_file_to_parse;
			};
			if (mycatch()) {
				mywarn("skipped index file '%s'", $index_file_to_parse);
			}
		}
	}

	$self->_process_provides_in_index_files(@index_files);

	# reading pin settings
	my $pin_settings_file = $self->_path_of_preferences();
	$self->_parse_preferences($pin_settings_file) if -r $pin_settings_file;

	# reading list of automatically installed packages
	my $extended_states_file = $self->_path_of_extended_states();
	$self->_parse_extended_states($extended_states_file) if -r $extended_states_file;

	return $self;
}

=head2 get_binary_packages

method, returns all binary packages as hash reference in form { $package_name
=> I<pkg> }, where I<pkg> is reference to L<Cupt::Cache::Pkg|Cupt::Cache::Pkg>

=cut

sub get_binary_packages ($) {
	my ($self) = @_;

	return $self->{_binary_packages};
}

=head2 get_system_state

method, returns reference to L<Cupt::System::State|Cupt::System::State>

=cut

sub get_system_state ($) {
	my ($self) = @_;

	return $self->{_system_state};
}

=head2 get_extended_info

method, returns info about extended package statuses in format:

  {
    'automatically_installed' => { I<package_name> => 1 },
  }

=cut

sub get_extended_info ($) {
	my ($self) = @_;

	return $self->{_extended_info};
}

=head2 is_automatically_installed

method, returns boolean value - is the package automatically installed
or not

Parameters:

I<package_name> - package name

=cut

sub is_automatically_installed ($$) {
	my ($self, $package_name) = @_;

	my $ref_auto_installed = $self->{_extended_info}->{'automatically_installed'};
	if (exists $ref_auto_installed->{$package_name} &&
		$ref_auto_installed->{$package_name})
	{
		return 1;
	} else {
		return 0;
	}
}

=head2 get_pin

method, returns pin value for the supplied version

Parameters:

I<version> - reference to L<Cupt::Cache::BinaryVersion|Cupt::Cache::BinaryVersion>

=cut

sub get_pin {
	my ($self, $version) = @_;
	my $result;

	my $update_pin = sub ($) {
		if (!defined($result)) {
			$result = $_[0];
		} elsif ($result < $_[0]) {
			$result = $_[0];
		}
	};

	# 'available as' array, excluding local version if it present
	my @avail_as = @{$version->{avail_as}};

	# look for installed package?
	if ($version->is_installed()) {
		# yes, this version is installed
		$update_pin->(100);
		shift @avail_as;
	}

	# release-dependent settings
	my $default_release = $self->{_config}->var("apt::default-release");
	foreach (@avail_as) {
		if (defined($default_release)) {
			if ($_->{release}->{archive} eq $default_release ||
				$_->{release}->{codename} eq $default_release)
			{
				$update_pin->(990);
				last; # no sense to search further, this is maximum
			}
		}
		if ($_->{release}->{archive} eq 'experimental') {
			$update_pin->(1);
		} else {
			$update_pin->(500);
		}
	}

	# looking in pin settings
	PIN:
	foreach my $pin (@{$self->{_pin_settings}}) {
		if (exists $pin->{'package_name'}) {
			my $value = $pin->{'package_name'};
			$version->{package_name} =~ m/$value/ or next PIN;
		}
		if (exists $pin->{'source_name'}) {
			my $value = $pin->{'source_name'};
			$version->{source_name} =~ m/$value/ or next PIN;
		}
		if (exists $pin->{'version'}) {
			my $value = $pin->{'version'};
			$version->{version_string} =~ m/$value/ or next PIN;
		}
		if (exists $pin->{'base_uri'}) {
			my $value = $pin->{'base_uri'};

			my $found = 0;
			foreach (@avail_as) {
				if ($_->{base_uri} =~ m/$value/) {
					$found = 1;
					last;
				}
			}
			$found or next PIN;
		}
		if (exists $pin->{'release'}) {
			while (my ($key, $value) = each %{$pin->{'release'}}) {
				my $value = $value;

				my $found = 0;
				foreach (@avail_as) {
					if (defined $_->{release}->{$key} &&
						$_->{release}->{$key} =~ m/$value/)
					{
						$found = 1;
						last;
					}
				}
				$found or next PIN;
			}
		}

		# yeah, all conditions satisfied here
		$update_pin->($pin->{'value'});
	}

	# discourage downgrading for pins <= 1000
	# downgradings will have pin <= 0
	if ($result <= 1000) {
		my $package_name = $version->{package_name};
		my $installed_version_string = $self->{_system_state}->get_installed_version_string($package_name);
		if (defined($installed_version_string)
			&& Cupt::Core::compare_version_strings($installed_version_string, $version->{version_string}) > 0)
		{
			$result -= 1000;
		}
	}

	$result += 1 if $version->is_signed();

	return $result;
}

=head2 get_binary_package

method, returns reference to appropriate L<Cupt::Cache::Pkg|Cupt::Cache::Pkg> for package name.
Returns undef if there is no such package in cache.

Parameters:

I<package_name> - package name to find

=cut

sub get_binary_package {
	my ($self, $package_name) = @_;
	if (exists $self->{_binary_packages}->{$package_name}) {
		return $self->{_binary_packages}->{$package_name};
	} else {
		return undef;
	}
};

=head2 get_sorted_pinned_versions

method to get sorted by "candidatness" versions in descending order

Parameters:

I<package> - reference to L<Cupt::Cache::Pkg|Cupt::Cache::Pkg>

Returns: [ { 'version' => I<version>, 'pin' => I<pin> }... ]

where:

I<version> - reference to L<Cupt::Cache::BinaryVersion|Cupt::Cache::BinaryVersion>

I<pin> - pin value

=cut

sub get_sorted_pinned_versions {
	my ($self, $package) = @_;

	my @result;
	state %cache;

	# caching results
	if ($o_memoize) {
		my $key = join(",", $self, $package);
		if (exists $cache{$key}) {
			return $cache{$key};
		} else {
			$cache{$key} = \@result;
			# the @result itself will be filled by under lines of code so at
			# next run moment cache will contain the correct result
		}
	}

	foreach my $version (@{$package->versions()}) {
		push @result, { 'version' => $version, 'pin' => $self->get_pin($version) };
	}

	do {
		use sort 'stable';
		# sort in descending order, first key is pin, second is version string
		@result = sort {
			$b->{'pin'} <=> $a->{'pin'} or 
			compare_versions($b->{'version'}, $a->{'version'})
		} @result;
	};

	return \@result;
}

=head2 get_policy_version

method, returns reference to L<Cupt::Cache::BinaryVersion|Cupt::Cache::BinaryVersion>, this is the version
of I<package>, which to be installed by cupt policy

Parameters:

I<package> - reference to L<Cupt::Cache::Pkg|Cupt::Cache::Pkg>, package to select versions from

=cut

sub get_policy_version {
	my ($self, $package) = @_;

	# selecting by policy
	# we assume that every existent package have at least one version
	# this is how we add versions in 'Cupt::Cache::&_process_index_file'

	# so, just return version with maximum "candidatness"
	return $self->get_sorted_pinned_versions($package)->[0]->{'version'};
}

sub _get_satisfying_versions_for_one_relation {
	my ($self, $relation) = @_;
	my $package_name = $relation->package_name;

	my @result;
	state %cache;

	# caching results
	if ($o_memoize) {
		my $key = join(",",
				$self,
				$package_name,
				$relation->relation_string // "",
				$relation->version_string // ""
		);
		if (exists $cache{$key}) {
			return @{$cache{$key}};
		} else {
			$cache{$key} = \@result;
			# the @result itself will be filled by under lines of code so at
			# next run moment cache will contain the correct result
		}
	}

	my $package = $self->get_binary_package($package_name);

	if (defined($package)) {
		# if such binary package exists
		my $ref_sorted_versions = $self->get_sorted_pinned_versions($package);
		foreach (@$ref_sorted_versions) {
			my $version = $_->{'version'};
			push @result, $version if $relation->satisfied_by($version->{version_string});
		}
	}

	# virtual package can only be considered if no relation sign is specified
	if (!defined($relation->relation_string) && exists $self->{_can_provide}->{$package_name}) {
		# looking for reverse-provides
		foreach (@{$self->{_can_provide}->{$package_name}}) {
			my $reverse_provide_package = $self->get_binary_package($_);
			defined ($reverse_provide_package) or next;
			foreach (@{$self->get_sorted_pinned_versions($reverse_provide_package)}) {
				my $version = $_->{version};
				foreach (@{$version->{provides}}) {
					my $provides_package_name = $_;
					if ($provides_package_name eq $package_name) {
						# ok, this particular version does provide this virtual package
						push @result, $version;
					}
				}
			}
		}
	}

	return @result;
}

=head2 get_satisfying_versions

method, returns reference to array of L<Cupt::Cache::BinaryVersion|Cupt::Cache::BinaryVersion>
that satisfy relation, if no version can satisfy the relation, returns an
empty array

Parameters:

I<relation_expression> - reference to L<Cupt::Cache::Relation|Cupt::Cache::Relation>, or relation OR
group (see L<Cupt::Cache::Relation reference|Cupt::Cache::Relation> for the info about OR
groups)

=cut

sub get_satisfying_versions ($$) {
	my ($self, $relation_expression) = @_;

	if (ref $relation_expression ne 'ARRAY') {
		# relation expression is just one relation
		return [ $self->_get_satisfying_versions_for_one_relation($relation_expression) ];
	} else {
		# othersise it's OR group of expressions
		my @result = map { $self->_get_satisfying_versions_for_one_relation($_) } @$relation_expression;
		# get rid of duplicates
		my %seen;
		@result = grep { !$seen{ $_->{package_name}, $_->{version_string} } ++ } @result;
		return \@result;
	}
}

our %_empty_release_info = (
	'version' => undef,
	'description' => undef,
	'signed' => 0,
	'vendor' => undef,
	'label' => undef,
	'archive' => undef,
	'codename' => undef,
	'date' => undef,
	'valid-until' => undef,
	'architectures' => undef,
);

sub _verify_signature ($$) {
	my ($self, $file) = @_;

	my $keyring_file = $self->{_config}->var('gpgv::trustedkeyring');

	my $signature_file = "$file.gpg";
	-r $signature_file or
			return 0;

	-r $keyring_file or
			do {
				mywarn("no read rights on keyring file '%s', please do 'chmod +r %s' with root rights",
						$keyring_file, $keyring_file);
				return 0;
			};

	open(GPG_VERIFY, "gpg --verify --status-fd 1 --no-default-keyring " .
			"--keyring $keyring_file $signature_file $file 2>/dev/null |") or
			mydie("unable to open gpg pipe: %s", $!);
	my $sub_gpg_readline = sub {
		my $result;
		do {
			$result = readline(GPG_VERIFY);
		} while (defined $result and (($result =~ m/^\[GNUPG:\] SIG_ID/) or !($result =~ m/^\[GNUPG:\]/)));

		if (!defined $result) {
			return undef;
		} else {
			$result =~ s/^\[GNUPG:\] //;
			return $result;
		}
	};
	my $verify_result;

	my $status_string = $sub_gpg_readline->();
	if (defined $status_string) {
		# first line ought to be validness indicator
		my ($message_type, $message) = ($status_string =~ m/(\w+) (.*)/);
		given ($message_type) {
			when ('GOODSIG') {
				my $further_info = $sub_gpg_readline->();
				defined $further_info or
						mydie("gpg: '%s': unfinished status");

				my ($check_result_type, $check_message) = ($further_info =~ m/(\w+) (.*)/);
				given ($check_result_type) {
					when ('VALIDSIG') {
						# no comments :)
						$verify_result = 1;
					}
					when ('EXPSIG') {
						$verify_result = 0;
						mywarn("gpg: '%s': expired signature: %s", $file, $check_message);
					}
					when ('EXPKEYSIG') {
						$verify_result = 0;
						mywarn("gpg: '%s': expired key: %s", $file, $check_message);
					}
					when ('REVKEYSIG') {
						$verify_result = 0;
						mywarn("gpg: '%s': revoked key: %s", $file, $check_message);
					}
					default {
						mydie("gpg: '%s': unknown error: %s %s", $file, $check_result_type, $check_message);
					}
				}
			}
			when ('BADSIG') {
				mywarn("gpg: '%s': bad signature: %s", $file, $message);
				$verify_result = 0;
			}
			when ('ERRSIG') {
				# gpg was not able to verify signature
				mywarn("gpg: '%s': could not verify signature: %s", $file, $message);
				$verify_result = 0;
			}
			when ('NODATA') {
				# no signature
				mywarn("gpg: '%s': empty signature", $file);
				$verify_result = 0;
			}
			default {
				mydie("gpg: '%s': unknown message received: %s %s", $file, $message_type, $message);
			}
		}
	} else {
		# no info from gpg at all
		mydie("error while verifying signature for file '%s'", $file);
	}

	close(GPG_VERIFY) or $! == 0 or
			mydie("unable to close gpg pipe: %s", $!);

	return $verify_result;
}

sub _get_release_info {
	my ($self, $file) = @_;

	my %release_info = %_empty_release_info;

	open(RELEASE, '<', $file) or mydie("unable to open release file '%s'", $file);
	my $field_name = undef;
	eval {
		while (<RELEASE>) {
			(($field_name, my $field_value) = ($_ =~ m/^((?:\w|-)+?): (.*)/)) # '$' implied in regexp
				or last;

			given ($field_name) {
				when ('Origin') { $release_info{vendor} = $field_value }
				when ('Label') { $release_info{label} = $field_value }
				when ('Suite') { $release_info{archive} = $field_value }
				when ('Codename') { $release_info{codename} = $field_value }
				when ('Date') { $release_info{date} = $field_value }
				when ('Valid-Until') { $release_info{valid_until} = $field_value }
				when ('Architectures') { $release_info{architectures} = [ split / /, $field_value ] }
				when ('Description') {
					$release_info{description} = $field_value;
					if ($field_value =~ m/([0-9a-z._-]+)/) {
						$release_info{version} = $1;
					}
				}
			}

			undef $field_name;
		}
	};
	if (mycatch()) {
		myerr("error parsing release file '%s', line '%d'", $file, $.);
		myredie();
	}
	if (!defined($release_info{description})) {
		mydie("no description specified in release file '%s'", $file);
	}
	if (!defined($release_info{vendor})) {
		mydie("no vendor specified in release file '%s'", $file);
	}
	if (!defined($release_info{archive})) {
		mydie("no archive specified in release file '%s'", $file);
	}
	if (!defined($release_info{codename})) {
		mydie("no codename specified in release file '%s'", $file);
	}

	close(RELEASE) or mydie("unable to close release file '%s'", $file);

	$release_info{signed} = $self->_verify_signature($file);

	return \%release_info;
}

sub _parse_sources_lists {
	my $self = shift;
	my $root_prefix = $self->{_config}->var('dir');
	my $etc_dir = $self->{_config}->var('dir::etc');

	my $parts_dir = $self->{_config}->var('dir::etc::sourceparts');
	my @source_files = glob("$root_prefix$etc_dir/$parts_dir/*");

	my $main_file = $self->{_config}->var('dir::etc::sourcelist');
	push @source_files, "$root_prefix$etc_dir/$main_file";

	my @result;
	foreach (@source_files) {
		push @result, __parse_source_list($_);
	}

	return \@result;
}

sub __parse_source_list {
	my $file = shift;
	my @result;
	open(HFILE, '<', "$file") or mydie("unable to open file %s: %s", $file, $!);
	while (<HFILE>) {
		chomp;
		# skip all empty lines and lines with comments
		next if m/^\s*(?:#.*)?$/;

		my %entry;
		($entry{'type'}, $entry{'uri'}, $entry{'distribution'}, my @sections) = split / +/;

		mydie("incorrent source line at file %s, line %d", $file, $.) if (!scalar @sections);
		mydie("incorrent source type at file %s, line %d", $file, $.)
			if ($entry{'type'} ne 'deb' && $entry{'type'} ne 'deb-src');

		map { $entry{'component'} = $_; push @result, { %entry }; } @sections;
	}
	close(HFILE) or mydie("unable to close file %s: %s", $file, $!);
	return @result;
}

sub _parse_preferences {
	my ($self, $file) = @_;

	# we are parsing triads like:

	# Package: perl
	# Pin: o=debian,a=unstable
	# Pin-Priority: 800

	# Source: unetbootin
	# Pin: a=experimental
	# Pin-Priority: 1100

	sub glob_to_regex ($) {
		$_[0] =~ s/\*/.*?/g;
		$_[0] =~ s/^/.*?/g;
		$_[0] =~ s/$/.*/g;
	}

	open(PREF, '<', $file) or mydie("unable to open file %s: %s'", $file, $!);
	while (<PREF>) {
		chomp;
		# skip all empty lines and lines with comments
		next if m/^\s*(?:#.*)?$/;

		# ok, real triad should be here
		my %pin_result;

		do { # processing first line
			m/^(Package|Source): (.*)/ or
					mydie("bad package/source line at file '%s', line '%u'", $file, $.);

			my $name_type = ($1 eq 'Package' ? 'package_name' : 'source_name');
			my $name_value = $2;
			glob_to_regex($name_value);

			$pin_result{$name_type} = $name_value;
		};

		do { # processing second line
			my $pin_line = <PREF>;
			defined($pin_line) or
					mydie("no pin line at file '%s' line '%u'", $file, $.);

			$pin_line =~ m/^Pin: (\w+?) (.*)/ or
					mydie("bad pin line at file '%s' line '%u'", $file, $.);

			my $pin_type = $1;
			my $pin_expression = $2;
			given ($pin_type) {
				when ('release') {
					my @conditions = split /,/, $pin_expression;
					scalar @conditions or
							mydie("bad release expression at file '%s' line '%u'", $file, $.);

					foreach (@conditions) {
						m/^(\w)=(.*)/ or
								mydie("bad condition in release expression at file '%s' line '%u'", $file, $.);

						my $condition_type = $1;
						my $condition_value = $2;
						given ($condition_type) {
							when ('a') { $pin_result{'release'}->{'archive'} = $condition_value; }
							when ('v') { $pin_result{'release'}->{'version'} = $condition_value; }
							when ('c') { $pin_result{'release'}->{'component'} = $condition_value; }
							when ('n') { $pin_result{'release'}->{'codename'} = $condition_value; }
							when ('o') { $pin_result{'release'}->{'vendor'} = $condition_value; }
							when ('l') { $pin_result{'release'}->{'label'} = $condition_value; }
							default {
								mydie("bad condition type (should be one of 'a', 'v', 'c', 'n', 'o', 'l') " . 
										"in release expression at file '%s' line '%u'", $file, $.);
							}
						}
					}
				}
				when ('version') {
					glob_to_regex($pin_expression);
					$pin_result{'version'} = $pin_expression;
				}
				when ('origin') { # this is 'base_uri', really...
					$pin_result{'base_uri'} = $pin_expression;
				}
				default {
					mydie("bad pin type (should be one of 'release', 'version', 'origin') " . 
							"at file '%s' line '%u'", $file, $.);
				}
			}
		};

		do { # processing third line
			my $priority_line = <PREF>;
			defined($priority_line) or
					mydie("no priority line at file '%s' line '%u'", $file, $.);

			$priority_line =~ m/^Pin-Priority: ([+-]?\d+)/ or
					mydie("bad priority line at file '%s' line '%u'", $file, $.);

			my $priority = $1;
			$pin_result{'value'} = $priority;
		};

		# adding to storage
		push @{$self->{'_pin_settings'}}, \%pin_result;
	}

	close(PREF) or mydie("unable to close file %s: %s", $file, $!);
}

sub _parse_extended_states {
	my ($self, $file) = @_;

	# we are parsing duals like:

	# Package: perl
	# Auto-Installed: 1

	eval {
		my $package_name;
		my $value;

		open(STATES, '<', $file) or mydie("unable to open file %s: %s'", $file, $!);
		while (<STATES>) {
			chomp;

			# skipping newlines
			next if $_ eq "";

			do { # processing first line
				m/^Package: (.*)/ or
						mydie("bad package line at file '%s', line '%u'", $file, $.);

				$package_name = $1;
			};

			do { # processing second line
				my $value_line = <STATES>;
				defined($value_line) or
						mydie("no value line at file '%s' line '%u'", $file, $.);

				$value_line =~ m/^Auto-Installed: (0|1)/ or
						mydie("bad value line at file '%s' line '%u'", $file, $.);

				$value = $1;
			};

			if ($value) {
				# adding to storage
				$self->{_extended_info}->{'automatically_installed'}->{$package_name} = $value;
			}
		}

		close(STATES) or mydie("unable to close file %s: %s", $file, $!);
	};
	if (mycatch()) {
		myerr("error while parsing extended states");
		myredie();
	}
}

sub _process_provides_in_index_files {
	my ($self, @files) = @_;

	eval {
		foreach my $file (@files) {
			open(FILE, '<', $file) or
					mydie("unable to open file '$file'");

			my $package_line = '';
			while(<FILE>) {
				next if !m/^Package: / and !m/^Provides: /;
				chomp;
				if (m/^Pa/) {
					$package_line = $_;
					next;
				} else {
					my ($package_name) = ($package_line =~ m/^Package: (.*)/);
					my ($provides_subline) = m/^Provides: (.*)/;
					my @provides = split /\s*,\s*/, $provides_subline;

					foreach (@provides) {
						# if this entry is new one?
						if (!grep { $_ eq $package_name } @{$self->{_can_provide}->{$_}}) {
							push @{$self->{_can_provide}->{$_}}, $package_name ;
						}
					}
				}
			}
			close(FILE) or
					mydie("unable to close file '$file'");
		}
	};
	if (mycatch()) {
		myerr("error parsing provides");
		myredie();
	}

}

sub _process_index_file {
	my ($self, $file, $ref_base_uri, $type, $ref_release_info) = @_;

	my $version_class;
	my $ref_packages_storage;
	if ($type eq 'deb') {
		$version_class = 'Cupt::Cache::BinaryVersion';
		$ref_packages_storage = \$self->{_binary_packages};
	} elsif ($type eq 'deb-src') {
		$version_class = 'Cupt::Cache::SourceVersion';
		$ref_packages_storage = \$self->{_source_packages};
		mywarn("not parsing deb-src index '%s' (parsing code is broken now)", $file);
		return;
	}

	my $fh;
	open($fh, '<', $file) or mydie("unable to open index file '%s'", $file);
	open(OFFSETS, "/bin/grep -b '^Package: ' $file |"); 

	eval {
		while (<OFFSETS>) {
			my ($offset, $package_name) = /^(\d+):Package: (.*)/;

			# offset is returned by grep -b, and we skips 'Package: <...>' line additionally
			$offset += length("Package: ") + length($package_name) + 1;

			# check it for correctness
			($package_name =~ m/^$package_name_regex$/)
				or mydie("bad package name '%s'", $package_name);

			# adding new entry (and possible creating new package if absend)
			Cupt::Cache::Pkg::add_entry($$ref_packages_storage->{$package_name} //= Cupt::Cache::Pkg->new(),
					$version_class, $package_name, $fh, $offset, $ref_base_uri, $ref_release_info);
		}
	};
	if (mycatch()) {
		myerr("error parsing index file '%s'", $file);
		myredie();
	}

	close(OFFSETS) or mydie("unable to close grep pipe");
}

sub _path_of_base_uri {
	my $self = shift;
	my $entry = shift;

	# "http://ftp.ua.debian.org" -> "ftp.ua.debian.org"
	(my $uri_prefix = $entry->{'uri'}) =~ s[^\w+://][];

	# stripping last '/' from uri if present
	$uri_prefix =~ s{/$}{};

	# "ftp.ua.debian.org/debian" -> "ftp.ua.debian.org_debian"
	$uri_prefix =~ tr[/][_];

	my $dirname = join('',
		$self->{_config}->var('dir'),
		$self->{_config}->var('dir::state'),
		'/',
		$self->{_config}->var('dir::state::lists')
	);

	my $base_uri_part = join('_',
		$uri_prefix,
		'dists',
		$entry->{'distribution'}
	);

	return join('', $dirname, '/', $base_uri_part);
}

sub _path_of_source_list {
	my $self = shift;
	my $entry = shift;

	my $arch = $self->{_config}->var('apt::architecture');
	my $suffix = ($entry->{'type'} eq 'deb') ? "binary-${arch}_Packages" : 'source_Sources';

	my $filename = join('_', $self->_path_of_base_uri($entry), $entry->{'component'}, $suffix);

	return $filename;
}

sub _path_of_release_list {
	my $self = shift;
	my $entry = shift;

	my $filename = join('_', $self->_path_of_base_uri($entry), 'Release');

	return $filename;
}

sub _path_of_preferences {
	my ($self) = @_;

	my $root_prefix = $self->{_config}->var('dir');
	my $etc_dir = $self->{_config}->var('dir::etc');

	my $leaf = $self->{_config}->var('dir::etc::preferences');

	return "$root_prefix$etc_dir/$leaf";
}

sub _path_of_extended_states {
	my ($self) = @_;

	my $root_prefix = $self->{_config}->var('dir');
	my $etc_dir = $self->{_config}->var('dir::state');

	my $leaf = $self->{_config}->var('dir::state::extendedstates');

	return "$root_prefix$etc_dir/$leaf";
}

=head1 Release info

TODO

=cut

1;

