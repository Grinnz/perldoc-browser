requires 'perl' => '5.020';
requires 'Capture::Tiny';
requires 'IPC::System::Simple';
requires 'List::Util' => '1.50';
requires 'MetaCPAN::Pod::XHTML';
requires 'Module::Metadata';
requires 'Mojolicious' => '7.84';
requires 'Perl::Build';
requires 'Pod::Simple::Search';
requires 'Pod::Simple::TextContent';
requires 'Sort::Versions';
requires 'Syntax::Keyword::Try';
requires 'experimental';
requires 'lib::relative';
requires 'version';

feature 'pg', 'PostgreSQL Backend', sub {
  requires 'Mojo::Pg' => '4.08';
};

feature 'es', 'Elasticsearch Backend', sub {
  requires 'Search::Elasticsearch' => '6.00';
  requires 'Log::Any::Adapter::MojoLog';
};
