class VirtualServer < ActiveRecord::Base
  attr_accessible :identity, :ip_address, :host_name, :hardware_server_id, 
    :orig_os_template, :password, :start_on_boot, :start_after_creation, :state,
    :nameserver, :search_domain, :diskspace, :memory, :password_confirmation,
    :user_id, :orig_server_template, :description, :cpu_units, :cpus, :cpu_limit,
    :expiration_date
  attr_accessor :password, :password_confirmation, :start_after_creation
  belongs_to :hardware_server
  belongs_to :user
  has_many :backups, :dependent => :destroy
  has_many :bean_counters, :dependent => :destroy
  
  validates_presence_of :identity
  validates_format_of :ip_address, :with => /^((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})|\s|(([\da-fA-F]{1,4}:?)|(::)){1,8})*$/
  validates_uniqueness_of :ip_address, :allow_blank => true
  validates_uniqueness_of :identity, :scope => :hardware_server_id
  validates_confirmation_of :password
  validates_format_of :nameserver, :with => /^((\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})|\s|(([\da-fA-F]{1,4}:?)|(::)){1,8})*$/
  validates_format_of :search_domain, :with => /^([a-z0-9\-\.]+\s*)*$/i
  validates_format_of :host_name, :with => /^[a-z0-9\-\.]*$/i
  validates_format_of :description, :with => /^[a-z0-9\-\.\s]*$/i if AppConfig.vzctl.save_descriptions

  def expiration_date=(date)
    write_attribute(:expiration_date, date.gsub('.', '-'))
  end

  def get_limits
    parser = IniParser.new(hardware_server.rpc_client.exec('cat', "/etc/vz/conf/#{identity.to_s}.conf")['output'])
    
    limits = [
      'KMEMSIZE', 'LOCKEDPAGES', 'SHMPAGES', 'NUMPROC', 
      'PHYSPAGES', 'VMGUARPAGES', 'OOMGUARPAGES', 'NUMTCPSOCK', 'NUMFLOCK',
      'NUMPTY', 'NUMSIGINFO', 'TCPSNDBUF', 'TCPRCVBUF', 'OTHERSOCKBUF',
      'DGRAMRCVBUF', 'NUMOTHERSOCK', 'DCACHESIZE', 'NUMFILE',
      'AVNUMPROC', 'NUMIPTENT', 'DISKINODES'
    ]
    
    result = []
    
    limits.each { |limit|
      raw_limit = parser.get(limit)
      raw_limit = 'unlimited' if raw_limit.blank?
      raw_limit = "#{raw_limit}:#{raw_limit}" if !raw_limit.include?(':')
      limit_values = raw_limit.split(":")
      limit_values[0] = '' if 'unlimited' == limit_values[0]
      limit_values[1] = '' if 'unlimited' == limit_values[1]
      result.push({ :name => limit, :soft_limit => limit_values[0], :hard_limit => limit_values[1] })
    }
    
    result
  end

  def start
    return true if 'running' == state
    change_state('start', 'running')
  end
  
  def stop
    return true if 'stopped' == state
    change_state('stop', 'stopped')
  end
  
  def restart
    change_state('restart', 'running')
  end
  
  def delete_physically
    stop
    hardware_server.rpc_client.exec('vzctl', 'destroy ' + identity.to_s)
    backups.each { |backup| backup.delete_physically }
    destroy
    EventLog.info("virtual_server.removed", { :identity => identity })
  end
  
  def save_limits(limits)
    orig_limits = get_limits
    vzctl_params = ''
    limits.each { |limit|
      orig_limit = orig_limits.find { |item| item[:name] == limit['name'] }
      if orig_limit[:soft_limit] != limit['soft_limit'] || orig_limit[:hard_limit] != limit['hard_limit']
        limit['soft_limit'] = 'unlimited' if '' == limit['soft_limit']
        limit['hard_limit'] = 'unlimited' if '' == limit['hard_limit']
        vzctl_params << "--" + limit['name'].downcase + " " + limit['soft_limit'].to_s + ":" + limit['hard_limit'].to_s + " "
      end
    }
    
    vzctl_set("#{vzctl_params} --save")
  end
  
  def save_physically
    return false if !valid?
    is_new = new_record?
    
    if is_new
      hardware_server.rpc_client.exec('vzctl', "create #{identity.to_s} --ostemplate #{orig_os_template} --config #{orig_server_template}")
      self.state = 'stopped'
    end
  
    if orig_server_template_changed?
      vzctl_set("--applyconfig #{orig_server_template} --save")
    end
    
    begin
      vzctl_set("--hostname #{host_name} --save") if !host_name.blank? and host_name_changed?
      vzctl_set("--userpasswd root:#{password}") if password and !password.blank?
      vzctl_set("--onboot " + (start_on_boot ? "yes" : "no") + " --save") if start_on_boot_changed?
      vzctl_set(nameserver.split.map { |ip| "--nameserver #{ip} " }.join + "--save") if !nameserver.blank? and nameserver_changed?
      vzctl_set("--searchdomain '#{search_domain}' --save") if !search_domain.blank? and search_domain_changed?
      vzctl_set("--cpuunits #{cpu_units} --save") if !cpu_units.blank? and cpu_units_changed?
      vzctl_set("--cpus #{cpus} --save") if !cpus.blank? and cpus_changed?
      vzctl_set("--cpulimit #{cpu_limit} --save") if !cpu_limit.blank? and cpu_limit_changed?
      vzctl_set("--description '#{description}' --save") if hardware_server.ve_descriptions_supported? and !description.empty? and description_changed?
      
      vzctl_set("--ipdel all --save") if !ip_address_was.blank? and ip_address_changed?
      vzctl_set(ip_address.split.map { |ip| "--ipadd #{ip} " }.join + "--save") if !ip_address.blank? and ip_address_changed?
      
      privvmpages = 0 == memory.to_i ? 'unlimited' : memory.to_i * 1024 / 4
      vzctl_set("--privvmpages #{privvmpages} --save") if memory_changed?
      disk = 0 == diskspace.to_i ? 'unlimited' : diskspace.to_i * 1024
      vzctl_set("--diskspace #{disk} --save") if diskspace_changed?
    rescue HwDaemonExecException => exception
      delete_physically if is_new
      raise exception
    end
    
    self.host_name = host_name_was if !is_new and host_name.blank?
    self.nameserver = nameserver_was if !is_new and nameserver.blank?
    self.search_domain = search_domain_was if !is_new and search_domain.blank?
    
    start if start_after_creation and is_new
  
    result = save
    EventLog.info("virtual_server." + (is_new ? "created" : "updated"), { :identity => identity })
    result
  end
  
  def reinstall
    was_running = 'running' == state
    path = '/etc/vz/conf'
    tmp_template = "tmp.template"
    
    new_os_template = ""
    if orig_os_template_changed?
      new_os_template = " --ostemplate #{orig_os_template} "
      save
    end
    
    hardware_server.rpc_client.exec("cp #{path}/#{self.identity}.conf #{path}/ve-#{tmp_template}.conf-sample")
    stop
    hardware_server.rpc_client.exec('vzctl', 'destroy ' + identity.to_s)
    hardware_server.rpc_client.exec('vzctl', "create #{identity.to_s} #{new_os_template} --config #{tmp_template}")
    change_state('start', 'running') if was_running
    hardware_server.rpc_client.exec("rm #{path}/ve-#{tmp_template}.conf-sample")
    
    true
  end
  
  def run_command(command)
    filename = "/tmp/vecmd_" + generate_id.to_s
    content = "#!/bin/sh\n#{command}"
    hardware_server.rpc_client.write_file(filename, content)
    
    begin
      result = hardware_server.rpc_client.exec('vzctl', "runscript #{identity.to_s} #{filename} ")
    rescue HwDaemonExecException => e
      result = { 'error' => e }
    end
      
    hardware_server.rpc_client.exec("rm #{filename}")
    result
  end
  
  def cpu_load_average
    run_command('cat /proc/loadavg')['output'].split[0..2]
  end
  
  def disk_usage
    raw_info = run_command('stat -c "%s %b %a" -f /')['output'].split
    info = {}
    info['block_size'] = raw_info[0].to_i
    info['total_bytes'] = info['block_size'] * raw_info[1].to_i
    info['free_bytes'] = info['block_size'] * raw_info[2].to_i
    info['used_bytes'] = info['total_bytes'] - info['free_bytes']
    info['usage_percent'] = (info['used_bytes'].to_f / info['total_bytes'].to_f * 100).to_i
    info
  end
  
  def memory_usage
    raw_info = run_command('free  -bo')['output'].split("\n")[1].split
    info = {}
    info['total_bytes'] = raw_info[1].to_i
    info['used_bytes'] = raw_info[2].to_i
    info['free_bytes'] = raw_info[3].to_i
    info['usage_percent'] = (info['used_bytes'].to_f / info['total_bytes'].to_f * 100).to_i
    info
  end
  
  def backup
    Backup.backup(self)
  end
  
  def private_dir
    hardware_server.ve_private.sub('$VEID', identity.to_s)
  end
  
  def human_diskspace
    0 != self.diskspace ? self.diskspace : I18n.translate('admin.virtual_servers.limits.unlimited')
  end
  
  def human_memory
    0 != self.memory ? self.memory : I18n.translate('admin.virtual_servers.limits.unlimited')
  end
  
  def suspend
    hardware_server.rpc_client.exec('vzctl', "chkpnt #{identity.to_s} --suspend")
  end
  
  def resume
    hardware_server.rpc_client.exec('vzctl', "chkpnt #{identity.to_s} --resume")
  end
  
  def clone_physically(orig_server)
    return false if !valid?
    
    path = '/etc/vz/conf'
    hardware_server.rpc_client.exec("cp #{path}/#{orig_server.identity}.conf #{path}/#{identity}.conf")
    
    orig_server.suspend
    hardware_server.rpc_client.exec("cp -a #{orig_server.private_dir} #{self.private_dir}")
    orig_server.resume
    
    begin
      vzctl_set("--userpasswd root:#{password}") if password and !password.blank?
      vzctl_set("--hostname #{host_name} --save") if !host_name.blank? and host_name_changed?
      vzctl_set("--ipdel all --save") if !ip_address_was.blank?
      vzctl_set(ip_address.split.map { |ip| "--ipadd #{ip} " }.join + "--save") if !ip_address.blank? and ip_address_changed?
    rescue HwDaemonExecException => exception
      raise exception
    end
    
    self.state = 'stopped'
    return false if !save
    
    start if 'running' == orig_server.state
    
    EventLog.info("virtual_server.cloned", { :identity => orig_server.identity })
    true
  end
  
  private

    def vzctl_set(param)
      hardware_server.rpc_client.exec('vzctl', "set #{identity.to_s} #{param}")
    end
    
    def change_state(state, status)
      begin
        hardware_server.rpc_client.exec('vzctl', state + ' ' + identity.to_s)
      rescue HwDaemonExecException => e
        EventLog.error("virtual_server.change_state_failed", {
          :identity => identity, :state => state, :code => e.code.to_s
        })
        return false
      end
      
      self.state = status
      save
    end
  
    def generate_id
      symbols = [('0'..'9'),('a'..'f')].map{ |i| i.to_a }.flatten
      (1..32).map{ symbols[rand(symbols.length)] }.join
    end
  
end
