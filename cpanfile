requires 'perl' => 'v5.42.0';
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
requires 'CBOR::XS';           # WebAuthn attestation object and COSE key decoding
requires 'CryptX';             # Crypt::PK::ECC (ES256), Crypt::PK::RSA (RS256), Crypt::PK::Ed25519 (EdDSA)
requires 'Crypt::URandom';     # Cryptographic random bytes for challenges and tokens
requires 'DBD::Pg';
requires 'Mojo::Pg';
requires 'Mojolicious';
requires 'Object::Pad';
requires 'Sub::Identify';
requires 'YAML::XS';
requires 'Test::PostgreSQL';
requires 'Test::MockObject';
requires 'Minion';
requires 'Minion::Backend::Pg';
requires 'Email::Simple';
requires 'Email::Sender::Simple';
requires 'JSON';
requires 'Text::Unidecode';
requires 'Text::CSV_XS';
requires 'IO::Socket::SSL';
requires 'SlapbirdAPM::Agent::Mojo';
