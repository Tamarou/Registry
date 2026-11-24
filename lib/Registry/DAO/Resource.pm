# ABOUTME: A PriceOps resource: something a tenant controls access to.
# ABOUTME: Finite resources carry a capacity; unbounded ones are limited only by policy.
use 5.42.0;
use utf8;

use Object::Pad;

class Registry::DAO::Resource :isa(Registry::DAO::Object) {
    field $id :param :reader;
    field $name :param :reader;
    field $kind :param :reader;    # 'finite' or 'unbounded'
    field $capacity :param :reader = undef;
    field $created_at :param :reader;

    sub table { 'resources' }
}

1;
