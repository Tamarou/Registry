use 5.40.2;
use Object::Pad;

# This file now only loads the individual workflow step classes
# Each workflow step is in its own file under WorkflowSteps/

use Registry::DAO::WorkflowSteps::CreateLocationWithAddress;
use Registry::DAO::WorkflowSteps::CreateProject;
use Registry::DAO::WorkflowSteps::CreateLocation;
use Registry::DAO::WorkflowSteps::RegisterTenant;
use Registry::DAO::WorkflowSteps::CreateEvent;
use Registry::DAO::WorkflowSteps::CreateSession;
use Registry::DAO::WorkflowSteps::CreateUser;
use Registry::DAO::WorkflowSteps::CreateWorkflow;
use Registry::DAO::WorkflowSteps::SelectProgram;
use Registry::DAO::WorkflowSteps::ChooseLocations;
use Registry::DAO::WorkflowSteps::ConfigureLocation;
use Registry::DAO::WorkflowSteps::GenerateEvents;

1;