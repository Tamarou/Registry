use 5.42.0;
# ABOUTME: Test helper for creating Stripe Connect test accounts on-the-fly against the real Stripe test API.
# ABOUTME: Implements the Leg 0 recipe: charges_enabled (ready) and unready accounts, cached per-process.
use Mojo::UserAgent ();

package Test::Registry::StripeConnect {

    my $BASE = 'https://api.stripe.com/v1';

    # Per-process cache: one ready and one unready account id.
    # ponytail: global per-process cache; separate per-worker if parallel suites matter
    my $_ready_id;
    my $_unready_id;

    # All acct_ ids created this process, for END-block cleanup.
    my @_created_ids;

    # Validate and return the test key.  Dies without interpolating the key value.
    # Every network helper calls this -- hard guard beyond available().
    sub _key {
        my $k = $ENV{STRIPE_SECRET_KEY} // '';
        die "STRIPE_SECRET_KEY must start with sk_test_ (live keys are forbidden in tests)\n"
            unless $k =~ /^sk_test_/;
        return $k;
    }

    # Returns true only when the environment carries a valid sk_test_ key.
    # Callers are responsible for skip_all when this returns false.
    sub available {
        return ( ( $ENV{STRIPE_SECRET_KEY} // '' ) =~ /^sk_test_/ ) ? 1 : 0;
    }

    sub _ua {
        return Mojo::UserAgent->new( connect_timeout => 10, inactivity_timeout => 30 );
    }

    sub _post {
        my ( $path, $params ) = @_;
        my $key = _key();
        my $tx  = _ua()->post(
            "$BASE$path",
            { Authorization => "Bearer $key" },
            form => $params,
        );
        my $data = $tx->res->json
            or die "Stripe POST $path: no JSON body (HTTP " . $tx->res->code . ")\n";
        die "Stripe POST $path error: $data->{error}{message}\n" if $data->{error};
        return $data;
    }

    sub _get {
        my ($path) = @_;
        my $key = _key();
        my $tx  = _ua()->get(
            "$BASE$path",
            { Authorization => "Bearer $key" },
        );
        my $data = $tx->res->json
            or die "Stripe GET $path: no JSON body (HTTP " . $tx->res->code . ")\n";
        die "Stripe GET $path error: $data->{error}{message}\n" if $data->{error};
        return $data;
    }

    sub _delete_account {
        my ($id) = @_;
        my $key = _key();
        my $tx  = _ua()->delete(
            "$BASE/accounts/$id",
            { Authorization => "Bearer $key" },
        );
        return $tx->res->json // {};
    }

    # Returns the acct_ id of a charges_enabled Custom connected account.
    # Creates one on first call using the Leg 0 magic values (Jenny Rosen / 1901-01-01 / SSN 000-00-0000 /
    # address_full_match), then polls GET /v1/accounts/{id} every 3 s until charges_enabled is true
    # (measured: ~48 s in the validated spike).  Subsequent calls return the cached id.
    # Aborts with a clear message if charges_enabled does not flip within 90 s.
    sub ready_account {
        return $_ready_id if defined $_ready_id;

        my $now  = time();
        my $acct = _post(
            '/accounts',
            {
                'type'                                   => 'custom',
                'country'                                => 'US',
                'email'                                  => 'jenny.rosen@tamarou.com',
                'business_type'                          => 'individual',
                'capabilities[card_payments][requested]' => 'true',
                'capabilities[transfers][requested]'     => 'true',
                'business_profile[mcc]'                  => '8299',
                'business_profile[url]'                  => 'https://tamarou.com',
                'individual[first_name]'                 => 'Jenny',
                'individual[last_name]'                  => 'Rosen',
                'individual[email]'                      => 'jenny.rosen@tamarou.com',
                'individual[phone]'                      => '0000000000',
                'individual[dob][day]'                   => '1',
                'individual[dob][month]'                 => '1',
                'individual[dob][year]'                  => '1901',
                'individual[ssn_last_4]'                 => '0000',
                'individual[id_number]'                  => '000000000',
                'individual[address][line1]'             => 'address_full_match',
                'individual[address][city]'              => 'South San Francisco',
                'individual[address][state]'             => 'CA',
                'individual[address][postal_code]'       => '94080',
                'individual[address][country]'           => 'US',
                'tos_acceptance[date]'                   => "$now",
                'tos_acceptance[ip]'                     => '8.8.8.8',
                'external_account'                       => 'btok_us_verified',
                'metadata[purpose]'                      => 'registry-test-suite',
            }
        );

        my $id = $acct->{id};
        push @_created_ids, $id;

        # Poll until charges_enabled.  Check immediately, then sleep 3 s between polls.
        my $deadline  = time() + 90;
        my $last_caps = {};
        while (1) {
            my $data = _get("/accounts/$id");
            if ( $data->{charges_enabled} ) {
                $_ready_id = $id;
                return $id;
            }
            $last_caps = $data->{capabilities} // {};
            die "Timed out after 90s waiting for charges_enabled on $id. "
              . "Last capability states: "
              . join( ', ', map { "$_=$last_caps->{$_}" } sort keys %$last_caps ) . "\n"
              if time() >= $deadline;
            sleep 3;
        }
    }

    # Returns the acct_ id of a Custom account that is NOT charges_enabled.
    # Omits tos_acceptance, external_account, and individual verification fields,
    # so it stays in pending_verification and never reaches charges_enabled.
    # Cached per-process; returns immediately without polling.
    sub unready_account {
        return $_unready_id if defined $_unready_id;

        my $acct = _post(
            '/accounts',
            {
                'type'                                   => 'custom',
                'country'                                => 'US',
                'email'                                  => 'unready@tamarou.com',
                'business_type'                          => 'individual',
                'capabilities[card_payments][requested]' => 'true',
                'capabilities[transfers][requested]'     => 'true',
                'metadata[purpose]'                      => 'registry-test-suite',
            }
        );

        my $id = $acct->{id};
        push @_created_ids, $id;
        $_unready_id = $id;
        return $id;
    }

    # Fetch raw account data from Stripe.  Exposed for tests to verify state.
    sub get_account {
        my ($id) = @_;
        return _get("/accounts/$id");
    }

    # Best-effort cleanup: delete every account created in this process.
    # Reports results via warn (shows as diag-style output under prove).
    END {
        local $?;
        return unless @_created_ids;

        # If the key is gone by END time, skip cleanup silently.
        return unless eval { _key(); 1 };

        my ( @cleaned, @failed );
        for my $id (@_created_ids) {
            my $result = eval { _delete_account($id) } // {};
            if ( $result->{deleted} ) {
                push @cleaned, $id;
            }
            else {
                push @failed, $id;
            }
        }

        my $msg = "# StripeConnect cleanup: deleted (" . join( ', ', @cleaned ) . ") ok";
        $msg .= "; failed to delete (" . join( ', ', @failed ) . ")" if @failed;
        warn "$msg\n";
    }
}

1;
