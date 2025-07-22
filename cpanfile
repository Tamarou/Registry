requires 'perl' => 'v5.40.2';
requires "Mojolicious::Plugin::HTMX";
requires 'App::Sqitch';
requires 'Clone';
requires 'Crypt::Passphrase';
requires 'DateTime';
requires 'DateTime::Format::Pg';
requires 'Function::Parameters';
requires 'Lexical::SealRequireHints';
requires 'Params::Util';
requires 'Crypt::Passphrase::Argon2';
requires 'Crypt::Passphrase::Bcrypt';
requires 'DBD::Pg';
requires 'Mojo::Pg';
requires 'Mojolicious';
requires 'Object::Pad';
requires 'Sub::Identify';
requires 'YAML::XS';
requires 'Test::PostgreSQL';
requires 'Test::MockObject';
# Stripe integration now uses custom async wrapper with Mojo::UserAgent
# requires 'WebService::Stripe'; # Replaced with Registry::Service::Stripe
requires 'Minion';
requires 'Minion::Backend::Pg';
requires 'Email::Simple';
requires 'Email::Sender::Simple';
requires 'JSON';
requires 'Text::Unidecode';
