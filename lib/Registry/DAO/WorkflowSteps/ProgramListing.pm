# ABOUTME: Workflow step for loading and presenting available programs and sessions.
# ABOUTME: Powers the tenant storefront by querying tenant-scoped program/session/pricing data.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::WorkflowSteps::ProgramListing :isa(Registry::DAO::WorkflowStep) {
    use Registry::DAO::Enrollment;
    use Registry::DAO::ProgramType;

    method process ($db, $form_data, $run = undef) {
        # The program-listing step stays on the page. Registration
        # happens via callcc links rendered in the template.
        return { stay => 1 };
    }

    method prepare_template_data ($db, $run) {
        $db = $db->db if $db isa Registry::DAO;

        # Load all published sessions with future end dates
        my $sessions = $db->query(q{
            SELECT DISTINCT s.*
            FROM sessions s
            JOIN session_events se ON se.session_id = s.id
            JOIN events e ON e.id = se.event_id
            WHERE s.status = 'published'
              AND s.end_date >= CURRENT_DATE
            ORDER BY s.start_date
        })->expand->hashes;

        # Group sessions by project (program)
        my %programs;
        for my $sess_row (@$sessions) {
            my $session = Registry::DAO::Session->new(%$sess_row);

            # Find the project via events linked to this session
            my $event_row = $db->query(q{
                SELECT e.project_id, e.location_id, e.capacity
                FROM events e
                JOIN session_events se ON se.event_id = e.id
                WHERE se.session_id = ?
                LIMIT 1
            }, $session->id)->hash;

            next unless $event_row && $event_row->{project_id};

            my $project = Registry::DAO::Project->find($db, { id => $event_row->{project_id} });
            next unless $project;

            my $project_id = $project->id;
            $programs{$project_id} ||= {
                project      => $project,
                program_type => undef,
                sessions     => [],
            };

            # Load program type if not already loaded
            if (!$programs{$project_id}{program_type} && $project->program_type_slug) {
                $programs{$project_id}{program_type} =
                    Registry::DAO::ProgramType->find_by_slug($db, $project->program_type_slug);
            }

            # Calculate availability
            my $capacity = $event_row->{capacity} || $session->capacity || 0;
            my $enrolled = Registry::DAO::Enrollment->count_for_session(
                $db, $session->id, ['active', 'pending']
            );
            my $available = $capacity > 0 ? $capacity - $enrolled : undef;
            my $is_full = defined $available && $available <= 0;

            # Get pricing
            my $pricing_plans = $session->pricing_plans($db);
            my $best_price = $session->get_best_price($db);

            push @{$programs{$project_id}{sessions}}, {
                session         => $session,
                enrolled_count  => $enrolled,
                capacity        => $capacity,
                available_spots => $available,
                is_full         => $is_full,
                has_waitlist    => $is_full,
                pricing_plans   => $pricing_plans,
                best_price      => $best_price,
                location_id     => $event_row->{location_id},
            };
        }

        # Sort by project name
        my @sorted = sort { $a->{project}->name cmp $b->{project}->name } values %programs;

        return {
            programs => \@sorted,
            run      => $run,
        };
    }
}
