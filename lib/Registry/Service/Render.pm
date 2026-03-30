# ABOUTME: Client for Render.com Custom Domains API. Handles adding, verifying,
# ABOUTME: and removing custom domains for tenant HTTPS provisioning.
#
# TRADE-OFF: These calls are synchronous/blocking. Admin domain-management
# actions are low-frequency and user-initiated, so blocking the request thread
# is acceptable here. Background verification polling (Task 9) runs in a
# Minion job to keep the HTTP latency off the request path entirely.
use 5.42.0;

use Object::Pad;

class Registry::Service::Render {
    use Carp qw(croak);
    use Mojo::UserAgent;
    use Mojo::JSON qw(decode_json encode_json);

    field $api_key    :param :reader;
    field $service_id :param :reader;
    field $ua         :param = Mojo::UserAgent->new;
    field $base_url   :param = 'https://api.render.com/v1';

    method _headers {
        return {
            Authorization  => "Bearer $api_key",
            'Content-Type' => 'application/json',
            Accept         => 'application/json',
        };
    }

    method _check_result ($tx) {
        my $res = $tx->result;
        unless ($res->is_success) {
            croak "Render API error: " . $res->body;
        }
        return $res;
    }

    # Add a custom domain to the Render service. Returns the domain object
    # created by Render, including the assigned domain ID.
    method add_custom_domain ($domain) {
        my $url = "$base_url/services/$service_id/custom-domains";
        my $tx  = $ua->post($url => $self->_headers => json => { name => $domain });
        return $self->_check_result($tx)->json;
    }

    # Trigger domain verification for a previously-added Render domain ID.
    # Returns the updated domain object with the current verification status.
    method verify_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id/verify";
        my $tx  = $ua->post($url => $self->_headers);
        return $self->_check_result($tx)->json;
    }

    # Remove a custom domain from the Render service. Returns 1 on success.
    method remove_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id";
        my $tx  = $ua->delete($url => $self->_headers);
        $self->_check_result($tx);
        return 1;
    }

    # Fetch the current status of a custom domain from Render. Returns the
    # domain object with verification status and DNS details.
    method get_custom_domain ($render_domain_id) {
        my $url = "$base_url/services/$service_id/custom-domains/$render_domain_id";
        my $tx  = $ua->get($url => $self->_headers);
        return $self->_check_result($tx)->json;
    }
}

1;
