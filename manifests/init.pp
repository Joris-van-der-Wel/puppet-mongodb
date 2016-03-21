class mongodb (
  $package_ensure     = $mongodb::params::package_ensure,
  $service_ensure     = $mongodb::params::service_ensure,
  $service_enable     = $mongodb::params::service_enable,
  $config             = $mongodb::params::config,
  $disable_huge_pages = $mongodb::params::disable_huge_pages,
  $mongo_fork         = $mongodb::params::mongo_fork,
  $configure_limits   = $mongodb::params::configure_limits,

) inherits mongodb::params {

  include mongodb::install_mongo, mongodb::install_percona, mongodb::install_tokumx2
  include mongodb::service

  if $mongo_fork != 'none' and
     $mongo_fork != 'percona' and
     $mongo_fork != 'tokumx2' {
    error('mongo_fork must either be "none" or "percona"')
  }

  if $disable_huge_pages {
    include mongodb::config_disable_huge_pages
  }

  if $configure_limits {
    include mongodb::config_configure_limits
  }

  if $mongo_fork == 'tokumx2' {
    include mongodb::config_tokumx2
  }
  else {
    include mongodb::config_mongodb
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
  $other_install_classes = [
    Class['mongodb::install_percona'],
    Class['mongodb::install_tokumx2'],
  ]

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
      'none' => $other_install_classes,
      default => [],
    },
  }
}

class mongodb::install_percona {
  $other_install_classes = [
    Class['mongodb::install_mongo'],
    Class['mongodb::install_tokumx2'],
  ]

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
      'percona' => $other_install_classes,
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
      ~> Class['mongodb::service']
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

class mongodb::install_tokumx2 {
  $other_install_classes = [
    Class['mongodb::install_mongo'],
    Class['mongodb::install_percona'],
  ]

  if $mongodb::mongo_fork == 'tokumx2' {
    package { 'tokumx-common':
      ensure   => 'present',
      provider => 'rpm',
      source   => 'https://s3.amazonaws.com/tokumx-2.0.1/el6/tokumx-common-2.0.1-1.el6.x86_64.rpm',
      require  => $mongodb::mongo_fork ? {
        'tokumx2' => $other_install_classes,
        default => [],
      }
    }

    Package['tokumx-common']
    ->
    package { 'tokumx':
      ensure   => 'present',
      require  => Package['tokumx-common'],
      provider => 'rpm',
      source   => 'https://s3.amazonaws.com/tokumx-2.0.1/el6/tokumx-2.0.1-1.el6.x86_64.rpm',
    }

    Package['tokumx-common']
    ->
    package { 'tokumx-server':
      ensure   => 'present',
      require  => Package['tokumx-common'],
      provider => 'rpm',
      source   => 'https://s3.amazonaws.com/tokumx-2.0.1/el6/tokumx-server-2.0.1-1.el6.x86_64.rpm',
    }
  }
  else {
    package { 'tokumx-common':
      ensure   => 'absent',
      provider => 'rpm',
    }

    package { 'tokumx':
      ensure   => 'absent',
      provider => 'rpm',
    }
    ->
    Package['tokumx-common']

    package { 'tokumx-server':
      ensure   => 'absent',
      provider => 'rpm',
    }
    ->
    Package['tokumx-common']
  }
}

class mongodb::config_disable_huge_pages {
  exec { '/sys/kernel/mm/transparent_hugepage/enabled':
    command => '/bin/echo never > /sys/kernel/mm/transparent_hugepage/enabled',
    unless => "/bin/grep -E '\\[never\\]|^never$' /sys/kernel/mm/transparent_hugepage/enabled",
  }
  ~> Class['mongodb::service']

  exec { '/sys/kernel/mm/transparent_hugepage/defrag':
    command => '/bin/echo never > /sys/kernel/mm/transparent_hugepage/defrag',
    unless => "/bin/grep -E '\\[never\\]|^never$' /sys/kernel/mm/transparent_hugepage/defrag",
  }
  ~> Class['mongodb::service']
}

class mongodb::config_configure_limits {
  $limits = @(CONF)
    mongod soft nproc unlimited
    mongod hard nproc unlimited
    | CONF

  file { '/etc/security/limits.d/mongod.conf':
    ensure => 'present',
    content => $limits,
  }
  ~> Class['mongodb::service']
}

class mongodb::config_mongodb {
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

  file { [
    '/var/log/mongodb',
    '/var/lib/mongodb',
    '/var/run/mongodb',
  ]:
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
    content => inline_template('<%= @config.to_yaml %>'),
    owner => 'root',
    group => 'root',
  }
  ~> Class['mongodb::service']
}

class mongodb::config_tokumx2 {
  $default_config = {
    dbpath => '/var/lib/mongo',
    logpath => '/var/log/mongo/tokumx.log',
    logappend => true,
    fork => true,
    pidfilepath => '/var/run/mongo/tokumx.pid',
    pluginsDir => '/usr/lib64/tokumx/plugins',
  }

  file { [
    '/var/lib/mongo',
    '/var/log/mongo',
    '/var/run/mongo',
  ]:
    ensure => directory,
    owner => 'tokumx',
    group => 'tokumx',
    require => [
      Class['mongodb::install_tokumx2'],
    ]
  }

  $config = deep_merge(
    $default_config,
    $mongodb::config,
    hiera_hash('mongodb::extra_config', {})
  )

  file { '/etc/tokumx.conf':
    ensure => file,
    content => inline_template('<%= tmp = "";@config.each_pair { |key, value| tmp += "#{key} = #{value}\n"};tmp %>'),
    owner => 'root',
    group => 'root',
  }
  ~> Class['mongodb::service']
}

class mongodb::service {
  if $os['family'] == 'RedHat' {
    $service_provider = $mongodb::mongo_fork ? {
      'percona' => 'systemd',
      'tokumx2' => 'redhat',
      default => 'redhat',
    }
  }
  else {
    $service_provider = undef
  }

  $service_name = $mongodb::mongo_fork ? {
    'tokumx2' => 'tokumx',
    default => 'mongod',
  }

  service { $service_name:
    require => [
      Class[$mongodb::mongo_fork ? {
        'tokumx2' => 'mongodb::config_tokumx2',
        default => 'mongodb::config_mongodb',
      }],
      Class['mongodb::install_mongo'],
      Class['mongodb::install_percona'],
      Class['mongodb::install_tokumx2'],
    ],
    provider => $service_provider,
    ensure => $mongodb::service_ensure,
    enable => $mongodb::service_enable,
  }
}
