requires 'perl' => '5.020';
requires 'File::Basename';
requires 'File::Copy';
requires 'File::Path';
requires 'File::pushd';
requires 'File::Spec';
requires 'File::Temp';
requires 'IPC::Run3';
requires 'Lingua::EN::Sentence';
requires 'List::Util' => '1.50';
requires 'MetaCPAN::Pod::XHTML' => '0.003002';
requires 'Module::Metadata';
requires 'Mojolicious' => '9.34';
requires 'Mojo::Log::Role::Clearable';
requires 'Perl::Build';
requires 'Pod::Simple' => '3.40';
requires 'Pod::Simple::Search';
requires 'Pod::Simple::TextContent';
requires 'Sort::Versions';
requires 'Syntax::Keyword::Try';
requires 'experimental';
requires 'lib::relative';
requires 'version';

feature 'install', 'Perl installation support', sub {
  requires 'Capture::Tiny';
  requires 'CPAN::Perl::Releases';
  requires 'CPAN::Perl::Releases::MetaCPAN';
  requires 'Devel::PatchPerl';
  requires 'Perl::Build';
  requires 'HTTP::Tiny';
  requires 'IO::Socket::SSL' => '1.56';
  requires 'Net::SSLeay' => '1.49';
};

feature 'pg', 'PostgreSQL search backend', sub {
  requires 'Mojo::Pg' => '4.08';
};

feature 'es', 'Elasticsearch search backend', sub {
  requires 'Search::Elasticsearch' => '8.00';
  requires 'Search::Elasticsearch::Client::8_0';
  requires 'Log::Any::Adapter::MojoLog';
};

feature 'sqlite', 'SQLite search backend', sub {
  requires 'Mojo::SQLite' => '3.001';
};
