use 5.40.2;
use experimental qw(signatures);

# ABOUTME: Controller for admin program management functionality
# ABOUTME: Handles program creation, updates, teacher assignments, and scheduling

package Registry::Controller::AdminPrograms {
    use Mojo::Base 'Mojolicious::Controller';

    sub index($self) {
        $self->render(
            template => 'admin/programs/index',
            programs => []
        );
    }

    sub new_program($self) {
        $self->render(
            template => 'admin/programs/new'
        );
    }

    sub create($self) {
        my $dao = $self->dao;
        my $params = $self->req->params->to_hash;

        # Store additional fields in metadata
        my $metadata = {
            type        => delete $params->{type},
            age_min     => delete $params->{age_min},
            age_max     => delete $params->{age_max},
            capacity    => delete $params->{capacity},
            price       => delete $params->{price},
        };

        my $program = $dao->create('Program', {
            name        => $params->{name},
            description => $params->{description},
            metadata    => $metadata
        });

        $self->flash(success => 'Program created successfully');
        $self->render(
            template => 'admin/programs/show',
            program  => $program
        );
    }

    sub edit($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $self->render(
            template => 'admin/programs/edit',
            program  => $program
        );
    }

    sub update($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });
        my $params = $self->req->params->to_hash;

        # Update metadata
        my $metadata = $program->metadata;
        $metadata->{capacity} = $params->{capacity} if exists $params->{capacity};
        $metadata->{price} = $params->{price} if exists $params->{price};

        $program->update($dao->db, {
            name        => $params->{name} // $program->name,
            description => $params->{description} // $program->description,
            metadata    => $metadata
        });

        $self->flash(success => 'Program updated successfully');
        $self->render(
            template => 'admin/programs/show',
            program  => $program
        );
    }

    sub teachers($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });
        my $teachers = $dao->find('User', { 'metadata->role' => 'teacher' });

        $self->render(
            template => 'admin/programs/teachers',
            program  => $program,
            teachers => $teachers
        );
    }

    sub assign_teacher($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $dao->create('ProgramTeacher', {
            program_id => $program->id,
            teacher_id => $self->param('teacher_id'),
            role       => $self->param('role') // 'instructor'
        });

        $self->flash(success => 'Teacher assigned successfully');
        $self->redirect_to('/admin/programs/' . $program->id . '/teachers');
    }

    sub schedule($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $self->render(
            template => 'admin/programs/schedule',
            program  => $program
        );
    }

    sub update_schedule($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });
        my $params = $self->req->params->to_hash;

        my $schedule = {
            start_date  => $params->{start_date},
            end_date    => $params->{end_date},
            days        => $params->{days},
            start_time  => $params->{start_time},
            end_time    => $params->{end_time},
            location_id => $params->{location_id}
        };

        $program->set_schedule($dao->db, $schedule);

        $self->flash(success => 'Schedule created successfully');
        $self->redirect_to('/admin/programs/' . $program->id . '/schedule');
    }

    sub show($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $self->render(
            template => 'admin/programs/show',
            program  => $program
        );
    }

    sub publish($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $program->publish($dao->db);

        $self->flash(success => 'Program published');
        $self->redirect_to('/admin/programs/' . $program->id);
    }

    sub archive($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $program->archive($dao->db);

        $self->flash(success => 'Program archived');
        $self->redirect_to('/admin/programs/' . $program->id);
    }

    sub clone_form($self) {
        my $dao = $self->dao;
        my $program = $dao->find('Program', { id => $self->param('id') });

        $self->render(
            template => 'admin/programs/clone',
            program  => $program
        );
    }

    sub clone($self) {
        my $dao = $self->dao;
        my $original = $dao->find('Program', { id => $self->param('id') });
        my $params = $self->req->params->to_hash;

        my $clone = $original->clone($dao->db, $params->{name}, {
            metadata => {
                %{$original->metadata},
                start_date => $params->{start_date},
                end_date   => $params->{end_date}
            }
        });

        $self->flash(success => 'Program cloned successfully');
        $self->redirect_to('/admin/programs/' . $clone->id);
    }
}

1;