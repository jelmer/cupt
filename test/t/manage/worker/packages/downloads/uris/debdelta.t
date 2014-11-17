use TestCupt;
use Test::More tests => 3;

use strict;
use warnings;

eval get_inc_code('common');

my $debdelta_conf = <<END;
[our archive]
delta_uri=http://deltas.info/pub

END

sub test {
	my ($debpatch_present, $version_of_bbb, $expected_bbb_addendum) = @_;

	my %parameters = (
		'debdelta_conf' => $debdelta_conf,
		'debpatch' => ($debpatch_present ? '' : undef),
		'packages2' => [
			{
				'content' =>
					entail(compose_package_record('bbb', $version_of_bbb) . "Filename: pool/b/bbb5.deb\n") .
					entail(compose_package_record('ccc', 4) . "Filename: pool/c/ccc4.deb\n"),
				'scheme' => 'https',
				'hostname' => 'debs.net',
			},
		],
		'expected_bbb' => 'https://debs.net/pool/b/bbb5.deb' . $expected_bbb_addendum,
		'expected_ccc' => 'https://debs.net/pool/c/ccc4.deb',
	);

	$parameters{'comment'} = "debpatch is present: $debpatch_present, version of bbb: $version_of_bbb";

	test_uris(%parameters);
}

sub compose_bbb_debdelta_addendum {
	my ($filename_part) = @_;
	return " | debdelta:http://deltas.info/pub/pool/b/$filename_part.debdelta";
}

test(0, 3, '');
test(1, 3, compose_bbb_debdelta_addendum('bbb_2_3_all'));
test(1, '7:4.6-8', compose_bbb_debdelta_addendum('bbb_2_7%253a4.6-8_all'));
