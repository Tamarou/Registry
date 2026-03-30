# ABOUTME: HTML email template renderer for Registry notification emails
# ABOUTME: Provides render() returning { html, text } with inline CSS and HTML escaping
use 5.42.0;

package Registry::Email::Template;

use Carp qw(carp);

# HTML-escape a scalar value for safe insertion into HTML
sub _escape_html {
    my ($val) = @_;
    return '' unless defined $val;
    my $s = "$val";
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

# Wrap content in the base HTML email layout
sub _html_layout {
    my ($content) = @_;
    return <<"END_HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Registry Notification</title>
</head>
<body style="margin:0;padding:0;background-color:#f4f4f4;font-family:Arial,Helvetica,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0" style="background-color:#f4f4f4;">
  <tr>
    <td align="center" style="padding:20px 0;">
      <table width="600" cellpadding="0" cellspacing="0" style="background-color:#ffffff;border-radius:8px;overflow:hidden;">
        <tr>
          <td style="background-color:#2c5f8a;padding:24px 32px;">
            <h1 style="margin:0;color:#ffffff;font-size:24px;font-weight:bold;">Registry</h1>
          </td>
        </tr>
        <tr>
          <td style="padding:32px;">
            $content
          </td>
        </tr>
        <tr>
          <td style="background-color:#f0f0f0;padding:16px 32px;border-top:1px solid #e0e0e0;">
            <p style="margin:0;color:#666666;font-size:12px;">
              This email was sent by the Registry system. Please do not reply to this email.
            </p>
          </td>
        </tr>
      </table>
    </td>
  </tr>
</table>
</body>
</html>
END_HTML
}

# Wrap content in a plain-text layout
sub _text_layout {
    my ($content) = @_;
    return <<"END_TEXT";
Registry
--------

$content

--
This email was sent by the Registry system.
END_TEXT
}

# Template definitions: each returns (html_body, text_body)
my %TEMPLATES = (

    enrollment_confirmation => sub {
        my (%v) = @_;
        my $name       = _escape_html($v{name}       // '');
        my $event      = _escape_html($v{event}      // '');
        my $start_date = _escape_html($v{start_date} // '');
        my $location   = _escape_html($v{location}   // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Enrollment Confirmed</h2>
<p style="color:#333333;line-height:1.6;">Hello $name,</p>
<p style="color:#333333;line-height:1.6;">Your enrollment has been confirmed for the following program:</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#f8f9fa;border-radius:4px;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Program:</td><td style="color:#333333;font-weight:bold;">$event</td></tr>
  <tr><td style="color:#666666;">Start Date:</td><td style="color:#333333;">$start_date</td></tr>
  <tr><td style="color:#666666;">Location:</td><td style="color:#333333;">$location</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">We look forward to seeing you!</p>
END

        my $raw_name  = $v{name}       // '';
        my $raw_event = $v{event}      // '';
        my $raw_date  = $v{start_date} // '';
        my $raw_loc   = $v{location}   // '';
        my $text = <<"END";
Enrollment Confirmed

Hello $raw_name,

Your enrollment has been confirmed for the following program:

  Program:    $raw_event
  Start Date: $raw_date
  Location:   $raw_loc

We look forward to seeing you!
END
        return ($html, $text);
    },

    waitlist_offer => sub {
        my (%v) = @_;
        my $name     = _escape_html($v{name}     // '');
        my $event    = _escape_html($v{event}    // '');
        my $deadline = _escape_html($v{deadline} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Waitlist Offer</h2>
<p style="color:#333333;line-height:1.6;">Hello $name,</p>
<p style="color:#333333;line-height:1.6;">A spot has opened up in <strong>$event</strong>. You have been offered a place from the waitlist.</p>
<p style="color:#333333;line-height:1.6;">Please respond by <strong>$deadline</strong> to confirm your enrollment.</p>
<p style="color:#333333;line-height:1.6;">If you do not respond by the deadline, your spot will be offered to the next person on the waitlist.</p>
END

        my $raw_name     = $v{name}     // '';
        my $raw_event    = $v{event}    // '';
        my $raw_deadline = $v{deadline} // '';
        my $text = <<"END";
Waitlist Offer

Hello $raw_name,

A spot has opened up in $raw_event. You have been offered a place from the waitlist.

Please respond by $raw_deadline to confirm your enrollment.

If you do not respond by the deadline, your spot will be offered to the next person on the waitlist.
END
        return ($html, $text);
    },

    attendance_alert => sub {
        my (%v) = @_;
        my $name       = _escape_html($v{name}       // '');
        my $event      = _escape_html($v{event}      // '');
        my $start_time = _escape_html($v{start_time} // '');
        my $location   = _escape_html($v{location}   // '');

        my $html = <<"END";
<h2 style="color:#c0392b;margin-top:0;">Attendance Alert</h2>
<p style="color:#333333;line-height:1.6;">Hello $name,</p>
<p style="color:#333333;line-height:1.6;">Attendance has not been recorded for the following event:</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#fff3f3;border-radius:4px;border-left:4px solid #c0392b;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Event:</td><td style="color:#333333;font-weight:bold;">$event</td></tr>
  <tr><td style="color:#666666;">Time:</td><td style="color:#333333;">$start_time</td></tr>
  <tr><td style="color:#666666;">Location:</td><td style="color:#333333;">$location</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">Please record attendance as soon as possible.</p>
END

        my $raw_name  = $v{name}       // '';
        my $raw_event = $v{event}      // '';
        my $raw_time  = $v{start_time} // '';
        my $raw_loc   = $v{location}   // '';
        my $text = <<"END";
Attendance Alert

Hello $raw_name,

Attendance has not been recorded for the following event:

  Event:    $raw_event
  Time:     $raw_time
  Location: $raw_loc

Please record attendance as soon as possible.
END
        return ($html, $text);
    },

    message_notification => sub {
        my (%v) = @_;
        my $name    = _escape_html($v{name}    // '');
        my $subject = _escape_html($v{subject} // '');
        my $body    = _escape_html($v{body}    // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">New Message</h2>
<p style="color:#333333;line-height:1.6;">Hello $name,</p>
<p style="color:#333333;line-height:1.6;">You have received a new message:</p>
<div style="background-color:#f8f9fa;border-radius:4px;padding:16px;margin:16px 0;">
  <p style="color:#2c5f8a;font-weight:bold;margin-top:0;">$subject</p>
  <p style="color:#333333;line-height:1.6;margin-bottom:0;">$body</p>
</div>
END

        my $raw_name    = $v{name}    // '';
        my $raw_subject = $v{subject} // '';
        my $raw_body    = $v{body}    // '';
        my $text = <<"END";
New Message

Hello $raw_name,

You have received a new message:

Subject: $raw_subject

$raw_body
END
        return ($html, $text);
    },

    magic_link_login => sub {
        my (%v) = @_;
        my $tenant_name      = _escape_html($v{tenant_name}      // '');
        my $magic_link_url   = _escape_html($v{magic_link_url}   // '');
        my $expires_in_hours = _escape_html($v{expires_in_hours} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Sign In to $tenant_name</h2>
<p style="color:#333333;line-height:1.6;">Click the link below to sign in to your account. This link will expire in $expires_in_hours hours.</p>
<p style="margin:24px 0;">
  <a href="$magic_link_url" style="background-color:#2c5f8a;color:#ffffff;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold;">Sign In</a>
</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">If you did not request this sign-in link, you can safely ignore this email.</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">Or copy and paste this URL into your browser:<br>$magic_link_url</p>
END

        my $raw_tenant_name      = $v{tenant_name}      // '';
        my $raw_magic_link_url   = $v{magic_link_url}   // '';
        my $raw_expires_in_hours = $v{expires_in_hours} // '';
        my $text = <<"END";
Sign In to $raw_tenant_name

Click the link below to sign in to your account. This link will expire in $raw_expires_in_hours hours.

$raw_magic_link_url

If you did not request this sign-in link, you can safely ignore this email.
END
        return ($html, $text);
    },

    magic_link_invite => sub {
        my (%v) = @_;
        my $tenant_name    = _escape_html($v{tenant_name}    // '');
        my $inviter_name   = _escape_html($v{inviter_name}   // '');
        my $role           = _escape_html($v{role}           // '');
        my $magic_link_url = _escape_html($v{magic_link_url} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">You've Been Invited to $tenant_name</h2>
<p style="color:#333333;line-height:1.6;"><strong>$inviter_name</strong> has invited you to join <strong>$tenant_name</strong> as a <strong>$role</strong>.</p>
<p style="color:#333333;line-height:1.6;">Click the link below to accept the invitation and set up your account.</p>
<p style="margin:24px 0;">
  <a href="$magic_link_url" style="background-color:#2c5f8a;color:#ffffff;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold;">Accept Invitation</a>
</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">If you were not expecting this invitation, you can safely ignore this email.</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">Or copy and paste this URL into your browser:<br>$magic_link_url</p>
END

        my $raw_tenant_name    = $v{tenant_name}    // '';
        my $raw_inviter_name   = $v{inviter_name}   // '';
        my $raw_role           = $v{role}           // '';
        my $raw_magic_link_url = $v{magic_link_url} // '';
        my $text = <<"END";
You've Been Invited to $raw_tenant_name

$raw_inviter_name has invited you to join $raw_tenant_name as a $raw_role.

Click the link below to accept the invitation and set up your account.

$raw_magic_link_url

If you were not expecting this invitation, you can safely ignore this email.
END
        return ($html, $text);
    },

    email_verification => sub {
        my (%v) = @_;
        my $tenant_name      = _escape_html($v{tenant_name}      // '');
        my $verification_url = _escape_html($v{verification_url} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Verify Your Email Address</h2>
<p style="color:#333333;line-height:1.6;">Thank you for registering with $tenant_name. Please verify your email address by clicking the link below.</p>
<p style="margin:24px 0;">
  <a href="$verification_url" style="background-color:#2c5f8a;color:#ffffff;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold;">Verify Email</a>
</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">If you did not create an account with $tenant_name, you can safely ignore this email.</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">Or copy and paste this URL into your browser:<br>$verification_url</p>
END

        my $raw_tenant_name      = $v{tenant_name}      // '';
        my $raw_verification_url = $v{verification_url} // '';
        my $text = <<"END";
Verify Your Email Address

Thank you for registering with $raw_tenant_name. Please verify your email address by clicking the link below.

$raw_verification_url

If you did not create an account with $raw_tenant_name, you can safely ignore this email.
END
        return ($html, $text);
    },

    passkey_registered => sub {
        my (%v) = @_;
        my $tenant_name = _escape_html($v{tenant_name} // '');
        my $device_name = _escape_html($v{device_name} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">New Passkey Added</h2>
<p style="color:#333333;line-height:1.6;">A new passkey has been added to your $tenant_name account.</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#f8f9fa;border-radius:4px;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Device:</td><td style="color:#333333;font-weight:bold;">$device_name</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">If you did not add this passkey, please contact support immediately and secure your account.</p>
END

        my $raw_tenant_name = $v{tenant_name} // '';
        my $raw_device_name = $v{device_name} // '';
        my $text = <<"END";
New Passkey Added

A new passkey has been added to your $raw_tenant_name account.

  Device: $raw_device_name

If you did not add this passkey, please contact support immediately and secure your account.
END
        return ($html, $text);
    },

    passkey_removed => sub {
        my (%v) = @_;
        my $tenant_name = _escape_html($v{tenant_name} // '');
        my $device_name = _escape_html($v{device_name} // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Passkey Removed</h2>
<p style="color:#333333;line-height:1.6;">A passkey has been removed from your $tenant_name account.</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#f8f9fa;border-radius:4px;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Device:</td><td style="color:#333333;font-weight:bold;">$device_name</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">If you did not remove this passkey, please contact support immediately and secure your account.</p>
END

        my $raw_tenant_name = $v{tenant_name} // '';
        my $raw_device_name = $v{device_name} // '';
        my $text = <<"END";
Passkey Removed

A passkey has been removed from your $raw_tenant_name account.

  Device: $raw_device_name

If you did not remove this passkey, please contact support immediately and secure your account.
END
        return ($html, $text);
    },

    domain_verified => sub {
        my (%v) = @_;
        my $tenant_name = _escape_html($v{tenant_name} // '');
        my $domain      = _escape_html($v{domain}      // '');

        my $html = <<"END";
<h2 style="color:#2c5f8a;margin-top:0;">Your Custom Domain Is Active</h2>
<p style="color:#333333;line-height:1.6;">Great news! Your custom domain has been verified and is now active for <strong>$tenant_name</strong>.</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#f8f9fa;border-radius:4px;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Domain:</td><td style="color:#333333;font-weight:bold;">$domain</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">Your site is now accessible at <strong>$domain</strong>.</p>
<div style="background-color:#fff8e1;border-left:4px solid #f59e0b;padding:12px 16px;margin:16px 0;border-radius:0 4px 4px 0;">
  <p style="color:#333333;line-height:1.6;margin:0;"><strong>Important:</strong> Because your domain has changed, any existing passkeys registered under the previous domain will no longer work. Please re-register your passkey on the new domain to continue using passwordless sign-in.</p>
</div>
END

        my $raw_tenant_name = $v{tenant_name} // '';
        my $raw_domain      = $v{domain}      // '';
        my $text = <<"END";
Your Custom Domain Is Active

Great news! Your custom domain has been verified and is now active for $raw_tenant_name.

  Domain: $raw_domain

Your site is now accessible at $raw_domain.

Important: Because your domain has changed, any existing passkeys registered under the previous domain will no longer work. Please re-register your passkey on the new domain to continue using passwordless sign-in.
END
        return ($html, $text);
    },

    domain_verification_failed => sub {
        my (%v) = @_;
        my $tenant_name = _escape_html($v{tenant_name} // '');
        my $domain      = _escape_html($v{domain}      // '');
        my $error       = _escape_html($v{error}       // '');
        my $retry_url   = _escape_html($v{retry_url}   // '');

        my $html = <<"END";
<h2 style="color:#c0392b;margin-top:0;">Domain Verification Failed</h2>
<p style="color:#333333;line-height:1.6;">We were unable to verify your custom domain for <strong>$tenant_name</strong>.</p>
<table cellpadding="8" cellspacing="0" style="width:100%;background-color:#fff3f3;border-radius:4px;border-left:4px solid #c0392b;margin:16px 0;">
  <tr><td style="color:#666666;width:120px;">Domain:</td><td style="color:#333333;font-weight:bold;">$domain</td></tr>
  <tr><td style="color:#666666;">Reason:</td><td style="color:#333333;">$error</td></tr>
</table>
<p style="color:#333333;line-height:1.6;">Please check your DNS settings and try again. Verification can be retried from your domain management page.</p>
<p style="margin:24px 0;">
  <a href="$retry_url" style="background-color:#2c5f8a;color:#ffffff;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold;">Manage Domains</a>
</p>
<p style="color:#666666;font-size:14px;line-height:1.6;">Or copy and paste this URL into your browser:<br>$retry_url</p>
END

        my $raw_tenant_name = $v{tenant_name} // '';
        my $raw_domain      = $v{domain}      // '';
        my $raw_error       = $v{error}       // '';
        my $raw_retry_url   = $v{retry_url}   // '';
        my $text = <<"END";
Domain Verification Failed

We were unable to verify your custom domain for $raw_tenant_name.

  Domain: $raw_domain
  Reason: $raw_error

Please check your DNS settings and try again. Verification can be retried from your domain management page.

$raw_retry_url
END
        return ($html, $text);
    },
);

# Render a named template with the given variables.
# Returns a hashref with keys 'html' and 'text'.
# Unknown templates return a generic fallback. Missing variables default to ''.
sub render {
    my ($class, $template_name, %vars) = @_;

    $template_name //= '';

    my $builder = $TEMPLATES{$template_name};

    unless ($builder) {
        carp "Unknown email template: '$template_name'" if $template_name ne '';
        # Generic fallback
        my $fallback_html = _html_layout('<p style="color:#333333;">No content available.</p>');
        my $fallback_text = _text_layout('No content available.');
        return { html => $fallback_html, text => $fallback_text };
    }

    my ($html_body, $text_body) = $builder->(%vars);

    return {
        html => _html_layout($html_body),
        text => _text_layout($text_body),
    };
}

1;
