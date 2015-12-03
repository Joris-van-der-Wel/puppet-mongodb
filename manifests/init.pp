class mongodb (
  $package_ensure = 'present',
  $service_ensure = 'running',
  $service_enable = true,
  $config = {},
  $disable_huge_pages = false,
) {
  include mongodb::install, mongodb::config, mongodb::service
}

class mongodb::install {
  file { '/etc/yum.repos.d/mongodb-org-3.0.repo':
    ensure => present,
    source => 'puppet:///modules/mongodb/mongodb-org-3.0.repo',
    owner => 'root',
    group => 'root',
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
    ensure => $mongodb::package_ensure
  }
}

class mongodb::config {
  $default_config = {
    systemLog => {
      destination => 'file',
      path => '/var/log/mongodb/mongod.log',
      logAppend => true,
    },
    processManagement => {
      fork => true,
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

  if $os['family'] == 'RedHat' {
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
  service { 'mongod':
    require => [Class['mongodb::config'], Class['mongodb::install']],
    ensure => $mongodb::service_ensure,
    enable => $mongodb::service_enable,
  }
}
