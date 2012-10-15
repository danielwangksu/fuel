#
# This can be used to build out the simplest openstack controller
#
#
# $export_resources - Whether resources should be exported
#
# [public_interface] Public interface used to route public traffic. Required.
# [public_address] Public address for public endpoints. Required.
# [private_interface] Interface used for vm networking connectivity. Required.
# [internal_address] Internal address used for management. Required.
# [mysql_root_password] Root password for mysql server.
# [admin_email] Admin email.
# [admin_password] Admin password.
# [keystone_db_password] Keystone database password.
# [keystone_admin_token] Admin token for keystone.
# [glance_db_password] Glance DB password.
# [glance_user_password] Glance service user password.
# [nova_db_password] Nova DB password.
# [nova_user_password] Nova service password.
# [rabbit_password] Rabbit password.
# [rabbit_user] Rabbit User.
# [network_manager] Nova network manager to use.
# [fixed_range] Range of ipv4 network for vms.
# [floating_range] Floating ip range to create.
# [create_networks] Rather network and floating ips should be created.
# [num_networks] Number of networks that fixed range should be split into.
# [multi_host] Rather node should support multi-host networking mode for HA.
#   Optional. Defaults to false.
# [auto_assign_floating_ip] Rather configured to automatically allocate and
#   assign a floating IP address to virtual instances when they are launched.
#   Defaults to false.
# [network_config] Hash that can be used to pass implementation specifc
#   network settings. Optioal. Defaults to {}
# [verbose] Rahter to log services at verbose.
# [export_resources] Rather to export resources.
# Horizon related config - assumes puppetlabs-horizon code
# [secret_key]          secret key to encode cookies, …
# [cache_server_ip]     local memcached instance ip
# [cache_server_port]   local memcached instance port
# [swift]               (bool) is swift installed
# [quantum]             (bool) is quantum installed
#   The next is an array of arrays, that can be used to add call-out links to the dashboard for other apps.
#   There is no specific requirement for these apps to be for monitoring, that's just the defacto purpose.
#   Each app is defined in two parts, the display name, and the URI
# [horizon_app_links]     array as in '[ ["Nagios","http://nagios_addr:port/path"],["Ganglia","http://ganglia_addr"] ]'
#
# [enabled] Whether services should be enabled. This parameter can be used to
#   implement services in active-passive modes for HA. Optional. Defaults to true.
class openstack::controller(
  # my address
  $public_address,
  $public_interface,
  $private_interface,
  $internal_address,
  $admin_address           = $internal_address,
  # connection information
  $mysql_root_password     = 'sql_pass',
  $custom_mysql_setup_class = undef,
  $admin_email             = 'some_user@some_fake_email_address.foo',
  $admin_password          = 'ChangeMe',
  $keystone_db_password    = 'keystone_pass',
  $keystone_admin_token    = 'keystone_admin_token',
  $glance_db_password      = 'glance_pass',
  $glance_user_password    = 'glance_pass',
  $nova_db_password        = 'nova_pass',
  $nova_user_password      = 'nova_pass',
  $rabbit_password         = 'rabbit_pw',
  $rabbit_user             = 'nova',
  $rabbit_cluster          = false,
  $rabbit_nodes            = [$internal_address],
  # network configuration
  # this assumes that it is a flat network manager
  $network_manager         = 'nova.network.manager.FlatDHCPManager',
  # this number has been reduced for performance during testing
  $fixed_range             = '10.0.0.0/16',
  $floating_range          = false,
  $create_networks         = true,
  $num_networks            = 1,
  $multi_host              = false,
  $auto_assign_floating_ip = false,
  # TODO need to reconsider this design...
  # this is where the config options that are specific to the network
  # types go. I am not extremely happy with this....
  $network_config          = {},
  # I do not think that this needs a bridge?
  $verbose                 = false,
  $export_resources        = true,
  $secret_key              = 'dummy_secret_key',
  $cache_server_ip         = ['127.0.0.1'],
  $cache_server_port       = '11211',
  $swift                   = false,
  $quantum                 = false,
  $horizon_app_links       = false,
  $enabled                 = true,
  $api_bind_address        = '0.0.0.0',
  $mysql_host              = '127.0.0.1',
  $service_endpoint        = '127.0.0.1',
  $galera_cluster_name = 'openstack',
  $galera_master_ip = '127.0.0.1',
  $galera_node_address = '127.0.0.1',
  $glance_backend
) {
  
  $glance_api_servers = "${service_endpoint}:9292"
  $nova_db = "mysql://nova:${nova_db_password}@${mysql_host}/nova"

  $rabbit_addresses = inline_template("<%= @rabbit_nodes.map {|x| x + ':5672'}.join ',' %>")
    $memcached_addresses =  inline_template("<%= @cache_server_ip.collect {|ip| ip + ':' + @cache_server_port }.join ',' %>")
 
  
  nova_config {'memcached_servers':
    value => $memcached_addresses
  }

  if ($export_resources) {
    # export all of the things that will be needed by the clients
    @@nova_config { 'rabbit_addresses': value => $rabbit_addresses }
    Nova_config <| title == 'rabbit_addresses' |>
    @@nova_config { 'sql_connection': value => $nova_db }
    Nova_config <| title == 'sql_connection' |>
    @@nova_config { 'glance_api_servers': value => $glance_api_servers }
    Nova_config <| title == 'glance_api_servers' |>
    @@nova_config { 'novncproxy_base_url': value => "http://${public_address}:6080/vnc_auto.html" }
    $sql_connection    = false
    $glance_connection = false
  } else {
    $sql_connection    = $nova_db
    $glance_connection = $glance_api_servers
  }

  include ntpd

  ####### DATABASE SETUP ######

  # set up mysql server
  class { "mysql::server":
    config_hash => {
      # the priv grant fails on precise if I set a root password
      # TODO I should make sure that this works
      # 'root_password' => $mysql_root_password,
      'bind_address'  => '0.0.0.0'
    },
    galera_cluster_name	=> $galera_cluster_name,
    galera_master_ip	=> $galera_master_ip,
    galera_node_address	=> $galera_node_address,
    enabled => $enabled,
    custom_setup_class => $custom_mysql_setup_class,
  }
  if ($enabled) {
    # set up all openstack databases, users, grants
    
    Class['keystone::config::mysql'] -> Exec<| title == 'keystone-manage db_sync' |>

    class { "keystone::db::mysql":
      host     => $mysql_host,
      password => $keystone_db_password,
      allowed_hosts => '%',
    }

    Class["glance::db::mysql"] -> Class['glance::registry']
    File['/etc/glance/glance-registry.conf'] -> Exec<| title == 'glance-manage db_sync' |>

    class { "glance::db::mysql":
      host     => $mysql_host,
      password => $glance_db_password,
      allowed_hosts => '%',
    }
    # TODO should I allow all hosts to connect?
    class { "nova::db::mysql":
      host          => $mysql_host,
      password      => $nova_db_password,
      allowed_hosts => '%',
    }
  }

  ####### KEYSTONE ###########

  # set up keystone
  class { 'keystone':
    package_ensure => $::openstack_version['keystone'],
    admin_token    => $keystone_admin_token,
    # we are binding keystone on all interfaces
    # the end user may want to be more restrictive
    bind_host      => $api_bind_address,
    log_verbose    => $verbose,
    log_debug      => $verbose,
    catalog_type   => 'sql',
    enabled        => $enabled,
  }
  # set up keystone database
  # set up the keystone config for mysql
  class { "keystone::config::mysql":
    host     => $mysql_host,
    password => $keystone_db_password,
  }

  if ($enabled) {
    # set up keystone admin users
    class { 'keystone::roles::admin':
      email    => $admin_email,
      password => $admin_password,
    }
    # set up the keystone service and endpoint
    class { 'keystone::endpoint':
      public_address   => $public_address,
      internal_address => $internal_address,
      admin_address    => $admin_address,
    }
    # set up glance service,user,endpoint
    class { 'glance::keystone::auth':
      password         => $glance_user_password,
      public_address   => $public_address,
      internal_address => $internal_address,
      admin_address    => $admin_address,
      before           => [Class['glance::api'], Class['glance::registry']]
    }
    # set up nova serice,user,endpoint
    class { 'nova::keystone::auth':
      password         => $nova_user_password,
      public_address   => $public_address,
      internal_address => $internal_address,
      admin_address    => $admin_address,
      before           => Class['nova::api'],
    }
  }

  ######## END KEYSTONE ##########

  ######## BEGIN GLANCE ##########


  class { 'glance::api':
    log_verbose       => $verbose,
    log_debug         => $verbose,
    auth_type         => 'keystone',
    auth_host         => $service_endpoint,
    auth_port         => '35357',
    auth_uri          => "http://${service_endpoint}:5000/",
    keystone_tenant   => 'services',
    keystone_user     => 'glance',
    keystone_password => $glance_user_password,
    enabled           => $enabled,
    bind_host         => $api_bind_address,
    registry_host     => $service_endpoint,
  }

  if $glance_backend == "swift"
  {
    #    package { "openstack-swift":
    #  ensure =>present,}
      Package["swift"] ~> Service['glance-api']
    
    class { "glance::backend::$glance_backend":
      swift_store_user => "services:glance",
      swift_store_key=> $glance_user_password,
      swift_store_create_container_on_put => "True",
      swift_store_auth_address => "http://${service_endpoint}:5000/v2.0/"
    }
  }
  else
  {
    class { "glance::backend::$glance_backend": }
  }
  



  class { 'glance::registry':
    log_verbose       => $verbose,
    log_debug         => $verbose,
    bind_host         => $api_bind_address,
    auth_type         => 'keystone',
    auth_host         => $service_endpoint,
    auth_port         => '35357',
    auth_uri          => "http://${service_endpoint}:5000/",
    keystone_tenant   => 'services',
    keystone_user     => 'glance',
    keystone_password => $glance_user_password,
    sql_connection    => "mysql://glance:${glance_db_password}@${mysql_host}/glance",
    enabled           => $enabled,
  }

  ######## END GLANCE ###########

  ######## BEGIN NOVA ###########


  class { 'nova::rabbitmq':
    userid        => $rabbit_user,
    password      => $rabbit_password,
    enabled       => $enabled,
    cluster       => $rabbit_cluster,
    cluster_nodes => $rabbit_nodes,
  }

  # TODO I may need to figure out if I need to set the connection information
  # or if I should collect it
  class { 'nova':
    ensure_package     => $::openstack_version['nova'],
    sql_connection     => $sql_connection,
    # this is false b/c we are exporting
    rabbit_nodes       => $rabbit_nodes,
    rabbit_userid      => $rabbit_user,
    rabbit_password    => $rabbit_password,
    image_service      => 'nova.image.glance.GlanceImageService',
    glance_api_servers => $glance_connection,
    verbose            => $verbose,
    api_bind_address   => $api_bind_address,
    admin_tenant_name => 'services',
    admin_user        => 'nova',
    admin_password    => $nova_user_password,
    auth_host		=> $service_endpoint,

  }

class {'nova::quota':
  quota_instances => 100,
  quota_cores => 100,
  quota_volumes => 100,
  quota_gigabytes => 1000,
  quota_floating_ips => 100,
  quota_metadata_items => 1024,
  quota_max_injected_files => 50,
  quota_max_injected_file_content_bytes => 102400,
  quota_max_injected_file_path_bytes => 4096
}
  class { 'nova::api':
    ensure_package    => $::openstack_version['nova'],
    enabled           => $enabled,
    # TODO this should be the nova service credentials
    #admin_tenant_name => 'openstack',
    #admin_user        => 'admin',
    #admin_password    => $admin_service_password,
#    admin_tenant_name => 'services',
#    admin_user        => 'nova',
#    admin_password    => $nova_user_password,
#    auth_host         => $service_endpoint,
  }

  class { [
    'nova::cert',
    'nova::consoleauth',
    'nova::scheduler',
    'nova::objectstore',
  ]:
    ensure_package => $::openstack_version['nova'],
    enabled        => $enabled,
  }

  class { 'nova::vncproxy':
    ensure_package => $::openstack_version['novncproxy'],
    enabled        => $enabled,
  }

  if $multi_host {
    nova_config { 'multi_host':   value => 'True'; }
    $enable_network_service = false
  } else {
    if $enabled == true {
      $enable_network_service = true
    } else {
      $enable_network_service = false
    }
  }

  if $enabled {
    $really_create_networks = $create_networks
  } else {
    $really_create_networks = false
  }

  # set up networking
  class { 'nova::network':
    ensure_package    => $::openstack_version['nova'],
    private_interface => $private_interface,
    public_interface  => $public_interface,
    fixed_range       => $fixed_range,
    floating_range    => $floating_range,
    network_manager   => $network_manager,
    config_overrides  => $network_config,
    create_networks   => $really_create_networks,
    num_networks      => $num_networks,
    enabled           => $enable_network_service,
    install_service   => $enable_network_service,
  }

  if $auto_assign_floating_ip {
    nova_config { 'auto_assign_floating_ip':   value => 'True'; }
  }

  ######## Horizon ########

  class { 'memcached':
    #    listen_ip => $api_bind_address,
  } 


  class { 'horizon':
    package_ensure => $::openstack_version['horizon'],
    bind_address => $api_bind_address,
    secret_key => $secret_key,
    cache_server_ip => $cache_server_ip,
    cache_server_port => $cache_server_port,
    swift => $swift,
    quantum => $quantum,
    horizon_app_links => $horizon_app_links,
    keystone_host => $service_endpoint,
  }


  ######## End Horizon #####

}
