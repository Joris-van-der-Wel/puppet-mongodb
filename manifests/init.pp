class mongodb (
  $package_ensure     = $mongodb::params::package_ensure,
  $service_ensure     = $mongodb::params::service_ensure,
  $service_enable     = $mongodb::params::service_enable,
  $config             = $mongodb::params::config,
  $disable_huge_pages = $mongodb::params::disable_huge_pages,
  $mongo_fork         = $mongodb::params::mongo_fork,
  $configure_limits   = $mongodb::params::configure_limits,

) inherits mongodb::params {

  include mongodb::install_mongo, mongodb::install_percona
  include mongodb::config, mongodb::service

  if $mongo_fork != 'none' and
     $mongo_fork != 'percona' {
    error('mongo_fork must either be "none" or "percona"')
  }
}

class mongodb::params {
  $package_ensure = 'present'
  $service_ensure = 'running'
  $service_enable = true
  $config = {}
  $disable_huge_pages = false
  $mongo_fork = 'none'

  if $os['family'] == 'RedHat' {
    $configure_limits = true
  }
  else {
    $configure_limits = false
  }
}

class mongodb::install_mongo {

  file { '/etc/yum.repos.d/mongodb-org-3.0.repo':
    ensure => $mongodb::mongo_fork ? {
      'none' => 'file',
      default => 'absent',
    },
    source => 'puppet:///modules/mongodb/mongodb-org-3.0.repo',
    owner  => 'root',
    group  => 'root',
  }
  ->
  package { 'mongodb-org':
    # do not install the meta package. otherwise puppet+yum is unable to downgrade the version
    ensure => absent,
  }
  ->
  package { [
    'mongodb-org-mongos',
    'mongodb-org-server',
    'mongodb-org-shell',
    'mongodb-org-tools'
  ]:
    ensure => $mongodb::mongo_fork ? {
      'none' => $mongodb::package_ensure,
      default => 'absent',
    },
    # make sure these have been removed first:
    require => $mongodb::mongo_fork ? {
      'none' => Class['mongodb::install_percona'],
      default => [],
    },
  }
}

class mongodb::install_percona {
  file { '/root/percona-release-0.1-3.noarch.rpm':
    ensure => $mongodb::mongo_fork ? {
      'percona' => 'file',
      default => 'absent',
    },
    source => 'puppet:///modules/mongodb/percona-release-0.1-3.noarch.rpm',
    owner  => 'root',
    group  => 'root',
  }
  ->
  package { 'percona-release':
    ensure => $mongodb::mongo_fork ? {
      'percona' => 'present',
      default => 'absent',
    },
    provider => 'rpm',
    source => '/root/percona-release-0.1-3.noarch.rpm',
  }
  ->
  package { 'Percona-Server-MongoDB':
    # do not install the meta package. otherwise puppet+yum is unable to downgrade the version
    ensure => absent,
  }
  ->
  package { [
    # 'Percona-Server-MongoDB-debuginfo',
    'Percona-Server-MongoDB-mongos',
    'Percona-Server-MongoDB-server',
    'Percona-Server-MongoDB-shell',
    'Percona-Server-MongoDB-tools',
  ]:
    ensure => $mongodb::mongo_fork ? {
      'percona' => $mongodb::package_ensure,
      default => 'absent',
    },
    # make sure these have been removed first:
    require => $mongodb::mongo_fork ? {
      'percona' => Class['mongodb::install_mongo'],
      default => [],
    },
  }

  if $mongodb::mongo_fork == 'percona' {
    $install_service = $mongodb::package_ensure ? {
      'absent' => false,
      'purged' => false,
      default => true,
    }

    if $install_service {
      # normally, the service definition is in Percona-Server-MongoDB
      file { '/usr/lib/systemd/system/mongod.service':
        ensure => 'present',
        source => 'puppet:///modules/mongodb/mongod-percona.service',
        owner  => 'root',
        group  => 'root',
      }
      ->
      exec { 'enable mongod systemd service file':
        command => '/bin/systemctl enable /usr/lib/systemd/system/mongod.service',
        unless => '/bin/systemctl is-enabled mongod.service',
      }
      ~> Service['mongod']
    }
    else {
      exec { 'disable mongod systemd service file':
        command => '/bin/systemctl disable /usr/lib/systemd/system/mongod.service',
        onlyif => '/bin/test -f /usr/lib/systemd/system/mongod.service && /bin/systemctl is-enabled mongod.service',
      }
      ->
      file { '/usr/lib/systemd/system/mongod.service':
        ensure => 'absent',
      }
    }
  }
}

class mongodb::config {
  $default_fork = $mongodb::mongo_fork ? {
    'percona' => false,
    default => true,
  }
  $default_config = {
    systemLog => {
      destination => 'file',
      path => '/var/log/mongodb/mongod.log',
      logAppend => true,
    },
    processManagement => {
      fork => $default_fork,
      pidFilePath => '/var/run/mongodb/mongod.pid',
    },
    storage => {
      dbPath => '/var/lib/mongo'
    }
  }

  $config = deep_merge(
    $default_config,
    $mongodb::config,
    hiera_hash('mongodb::extra_config', {})
  )

  file { '/var/log/mongodb':
    ensure => directory,
    owner => 'mongod',
    group => 'mongod',
    require => [
      Class['mongodb::install_mongo'],
      Class['mongodb::install_percona']
    ]
  }

  file { '/var/run/mongodb':
    ensure => directory,
    owner => 'mongod',
    group => 'mongod',
    require => [
      Class['mongodb::install_mongo'],
      Class['mongodb::install_percona']
    ]
  }

  file { '/etc/mongod.conf':
    ensure => file,
    content => inline_template("<%= @config.to_yaml %>"),
    owner => 'root',
    group => 'root',
  }
  ~> Service['mongod']

  if $mongodb::disable_huge_pages {
    exec { '/sys/kernel/mm/transparent_hugepage/enabled':
      command => '/bin/echo never > /sys/kernel/mm/transparent_hugepage/enabled',
      unless => "/bin/grep -E '\\[never\\]|^never$' /sys/kernel/mm/transparent_hugepage/enabled",
    }
    ~> Service['mongod']

    exec { '/sys/kernel/mm/transparent_hugepage/defrag':
      command => '/bin/echo never > /sys/kernel/mm/transparent_hugepage/defrag',
      unless => "/bin/grep -E '\\[never\\]|^never$' /sys/kernel/mm/transparent_hugepage/defrag",
    }
    ~> Service['mongod']
  }

  if $mongodb::configure_limits {
    $limits = @(CONF)
      mongod soft nproc unlimited
      mongod hard nproc unlimited
      | CONF

    file { '/etc/security/limits.d/mongod.conf':
      ensure => 'present',
      content => $limits,
    }
    ~> Service['mongod']
  }
}

class mongodb::service {
  if $os['family'] == 'RedHat' {
    $service_provider = $mongodb::mongo_fork ? {
      'percona' => 'systemd',
      default => 'redhat',
    }
  }
  else {
    $service_provider = undef
  }

  service { 'mongod':
    require => [
      Class['mongodb::config'],
      Class['mongodb::install_mongo'],
      Class['mongodb::install_percona']
    ],
    provider => $service_provider,
    ensure => $mongodb::service_ensure,
    enable => $mongodb::service_enable,
  }
}
