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
requires 'Module::Runtime';    # loads workflow step classes without a string eval
requires 'Object::Pad';
requires 'Sub::Identify';
requires 'YAML::XS';
requires 'Test::PostgreSQL';
requires 'Test::MockObject';
requires 'Capture::Tiny';    # tests capture stderr from failure paths they provoke
requires 'Minion';
requires 'Minion::Backend::Pg';
requires 'Email::Simple';
requires 'Email::Sender::Simple';
requires 'JSON';
requires 'Text::Unidecode';
requires 'Text::CSV_XS';
requires 'IO::Socket::SSL';
# IO::Socket::SSL's Makefile.PL adds Mozilla::CA as a prerequisite at build
# time when OpenSSL's OPENSSLDIR has no CA store, as on CI's setup-perl
# toolchain. `carton install --deployment` refuses anything the snapshot does
# not name, so it is pinned here rather than left to that decision.
requires 'Mozilla::CA';
requires 'SlapbirdAPM::Agent::Mojo';
requires 'CBOR::XS';
requires 'CryptX';
requires 'Crypt::URandom';
