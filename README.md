# Registry - Registration software for events

Registry is an educational platform for after-school programs, simplifying
event management, student tracking, and parent-teacher communication.

## Getting Started

### Using Registry

The simplest way to get started is to use our hosted platform at
[registry.tamarou.com](https://registry.tamarou.com).

Alternatively, you can run Registry locally using Docker:

```bash
# Clone the repository
git clone https://github.com/Tamarou/Registry.git
cd Registry

# Build and run the Registry container
docker build -t registry .
docker run -p 3000:3000 registry

# Registry will be available at http://localhost:3000
```

### Understanding Registry

To better understand the system:
1. Read our [mission and vision](docs/MISSION.md)
2. Review our [user personas](docs/personas/)
3. Explore our [architectural documentation](docs/architecture/)

### Development

For developers interested in contributing:
1. Review [CONTRIBUTING.md](CONTRIBUTING.md) for core concepts
2. Check out our workflow examples in `workflows/`
3. Examine our schema definitions in `schemas/`
4. Look through our templates in `templates/`

## Copyright & License

This software is copyright (c) 2024 by Tamarou LLC.

This is free software; you can redistribute it and/or modify it under the same
terms as the Perl 5 programming language system itself.