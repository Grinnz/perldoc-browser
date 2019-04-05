requires 'perl' => '5.020';
requires 'IPC::Run3';
requires 'List::Util' => '1.50';
requires 'MetaCPAN::Pod::XHTML';
requires 'Module::Metadata';
requires 'Mojolicious' => '8.0';
requires 'Mojo::Log::Role::Clearable';
requires 'Perl::Build';
requires 'Pod::Simple::Search';
requires 'Pod::Simple::TextContent';
requires 'Sort::Versions';
requires 'Syntax::Keyword::Try';
requires 'experimental';
requires 'lib::relative';
requires 'version';

feature 'install', 'Perl installation support', sub {
  requires 'Capture::Tiny';
  requires 'Perl::Build';
  requires 'HTTP::Tiny';
  requires 'IO::Socket::SSL' => '1.56';
  requires 'Net::SSLeay' => '1.49';
};

feature 'pg', 'PostgreSQL search backend', sub {
  requires 'Mojo::Pg' => '4.08';
};

feature 'es', 'Elasticsearch search backend', sub {
  requires 'Search::Elasticsearch' => '6.00';
  requires 'Log::Any::Adapter::MojoLog';
};

feature 'sqlite', 'SQLite search backend', sub {
  requires 'Mojo::SQLite' => '3.001';
};
