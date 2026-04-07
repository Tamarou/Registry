# ABOUTME: Workflow step for loading and presenting available programs and sessions.
# ABOUTME: Powers the tenant storefront by querying tenant-scoped program/session/pricing data.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramListing :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Enrollment;
    use Registry::DAO::ProgramType;
    use Registry::DAO::Session;

    method process ($db, $form_data, $run = undef) {
        # The program-listing step stays on the page. Registration
        # happens via callcc links rendered in the template.
        return { stay => 1 };
    }

    method prepare_template_data ($db, $run, $params = {}) {
        $db = $db->db if $db isa Registry::DAO;

        # Single consolidated query: sessions + events + projects + enrollment counts
        my $rows = $db->query(q{
            SELECT
                s.id AS session_id,
                s.name AS session_name,
                s.slug AS session_slug,
                s.start_date,
                s.end_date,
                s.status,
                s.capacity AS session_capacity,
                s.metadata AS session_metadata,
                s.created_at AS session_created_at,
                s.updated_at AS session_updated_at,
                e.project_id,
                e.location_id,
                e.capacity AS event_capacity,
                p.id AS proj_id,
                p.name AS project_name,
                p.slug AS project_slug,
                p.notes AS project_notes,
                p.program_type_slug,
                p.metadata AS project_metadata,
                p.created_at AS project_created_at,
                p.updated_at AS project_updated_at,
                COUNT(en.id) FILTER (WHERE en.status IN ('active', 'pending')) AS enrolled_count
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            JOIN projects p ON p.id = e.project_id
            LEFT JOIN enrollments en ON en.session_id = s.id
            WHERE s.status = 'published'
              AND s.end_date >= CURRENT_DATE
            GROUP BY s.id, s.name, s.slug, s.start_date, s.end_date, s.status,
                     s.capacity, s.metadata, s.created_at, s.updated_at,
                     e.project_id, e.location_id, e.capacity,
                     p.id, p.name, p.slug, p.notes, p.program_type_slug, p.metadata,
                     p.created_at, p.updated_at
            ORDER BY p.name, s.start_date
        })->expand->hashes;

        # Load pricing plans in a single query for all sessions
        my @session_ids = map { $_->{session_id} } @$rows;
        my %pricing_by_session;
        if (@session_ids) {
            my $placeholders = join(',', ('?') x @session_ids);
            my $pricing_rows = $db->query(
                "SELECT * FROM pricing_plans WHERE session_id IN ($placeholders)",
                @session_ids
            )->expand->hashes;

            for my $pr (@$pricing_rows) {
                push @{$pricing_by_session{$pr->{session_id}}}, $pr;
            }
        }

        # Load program types in a single query
        my %program_types;
        my @type_slugs = grep { defined $_ } map { $_->{program_type_slug} } @$rows;
        if (@type_slugs) {
            my @unique_slugs = keys %{{ map { $_ => 1 } @type_slugs }};
            for my $slug (@unique_slugs) {
                $program_types{$slug} = Registry::DAO::ProgramType->find_by_slug($db, $slug);
            }
        }

        # Group into programs structure
        my %programs;
        for my $row (@$rows) {
            my $project_id = $row->{proj_id};

            $programs{$project_id} ||= {
                project      => Registry::DAO::Project->new(
                    id                => $row->{proj_id},
                    name              => $row->{project_name},
                    slug              => $row->{project_slug},
                    notes             => $row->{project_notes},
                    program_type_slug => $row->{program_type_slug},
                    metadata          => $row->{project_metadata} || {},
                    created_at        => $row->{project_created_at},
                    updated_at        => $row->{project_updated_at},
                ),
                program_type => $row->{program_type_slug}
                    ? $program_types{$row->{program_type_slug}}
                    : undef,
                sessions     => [],
            };

            my $capacity = $row->{event_capacity} || $row->{session_capacity} || 0;
            my $enrolled = $row->{enrolled_count} || 0;
            my $available = $capacity > 0 ? $capacity - $enrolled : undef;
            my $is_full = defined $available && $available <= 0;

            # Get best price from pre-loaded pricing
            my $plans = $pricing_by_session{$row->{session_id}} || [];
            my $best_price;
            for my $plan (@$plans) {
                my $amount = $plan->{amount};
                $best_price = $amount if defined $amount && (!defined $best_price || $amount < $best_price);
            }

            push @{$programs{$project_id}{sessions}}, {
                session         => Registry::DAO::Session->new(
                    id         => $row->{session_id},
                    name       => $row->{session_name},
                    slug       => $row->{session_slug},
                    start_date => $row->{start_date},
                    end_date   => $row->{end_date},
                    status     => $row->{status},
                    capacity   => $row->{session_capacity},
                    metadata   => $row->{session_metadata} || {},
                    created_at => $row->{session_created_at},
                    updated_at => $row->{session_updated_at},
                ),
                enrolled_count  => $enrolled,
                capacity        => $capacity,
                available_spots => $available,
                is_full         => $is_full,
                has_waitlist    => $is_full,
                pricing_plans   => $plans,
                best_price      => $best_price,
                location_id     => $row->{location_id},
            };
        }

        my @sorted = sort { $a->{project}->name cmp $b->{project}->name } values %programs;

        return {
            programs => \@sorted,
            run      => $run,
        };
    }
}
