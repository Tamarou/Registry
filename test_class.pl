#!/usr/bin/env perl
use 5.40.2;
use experimental qw(try signatures);
use lib 'lib';
use Object::Pad;
use Registry::DAO::WorkflowStep;

class TestReview :isa(Registry::DAO::WorkflowStep) {
    use Carp qw(croak);

    method process($db, $form_data) {
        return { stay => 1 };
    }

    method prepare_template_data($db, $run) {
        return {};
    }
}

say "Class compiled successfully";
1;