class Script < ActiveRecord::Base
  attr_accessible :name, :url, :body, :body_url,
                  :docker_host, :docker_container_id, :docker_status

  validates :user_id, :presence => true
  validates :name, :presence => true, :uniqueness => {:scope => :user_id}

  scope :valid, lambda { where("deleted = ?", false) }

  belongs_to :user
  has_many :runs, :class_name => 'ScriptRun'

  after_destroy :rethink_delete

  extend FriendlyId
  friendly_id :name, use: :slugged

  include Workflow
  workflow_column :docker_status

  workflow do
    state :stopped do
      event :start, :transitions_to => :running
    end
    state :running do
      event :stop, :transitions_to => :stopped
    end

  end

  include RethinkDB::Shortcuts

  def self.safe_create(params)
    script = Script.new
    #defaults
    script.deleted = false

    script.name = params[:name]
    script.save
    script
  end

  def safe_update(params)
    unless params[:name].blank?
      self.name = params[:name]
    end
    unless params[:url].blank?
      self.url = params[:url]
      # response = RestClient.get(params[:url])
    end
    unless params[:body].blank?
      r.table('scripts').get(script_name).update(body:params[:body]).run(R)
    end
    save
  end

  def rethink_insert
    r.table('scripts').insert(id:script_name, key:UUID.generate).run(R)
  end

  def rethink_delete
    r.table('scripts').get(script_name).delete.run(R)
  end

  def script_name
    "#{user.username}/#{name}"
  end

  def body
    doc = r.table('scripts').get(script_name).run(R)
    doc ? doc["body"] : nil
  end

  def key
    doc = r.table('scripts').get(script_name).run(R)
    doc ? doc["key"] : nil
  end

  def start
    unless docker_container_id
      id = build_container
      if id
        logger.info ("Script #{user.username}/#{name} container created id ##{id}")
        update_attribute :docker_container_id, id
      else
        # error alert
        logger.error "Script #{user.username}/#{name} cointainer build failed"
        halt
      end
    end
    begin
      logger.info "Script#start #{docker_container_id} "+result.inspect
      result = docker.containers.start(docker_container_id)
      detail = docker.containers.show(docker_container_id)
      logger.info detail.inspect
    rescue Docker::Error::ContainerNotFound
      # bogus container id
      logger.info "Script#start #{docker_container_id} not found"
      update_attribute :docker_container_id, nil
      halt
    end
  end

  def stop
    if docker_container_id
      begin
        result = docker.containers.stop(docker_container_id)
        logger.info "stop #{docker_container_id} "+result.inspect
      rescue Docker::Error::ContainerNotFound
        # bogus container id, set to stopped anyways
        logger.info "stop #{docker_container_id} not found"
      end
    end
  end

  def docker
    host = docker_host || SETTINGS["docker"]["default_host"]
    unless docker_host
      update_attribute :docker_host, host
    end
    Docker::API.new(base_url: "http://#{host}:4243")
  end

  def build_container
    result = docker.containers.create(['cointhink-guest', user.username, name],
                                      SETTINGS["docker"]["image"],
                                      {"Env"=>["cointhink_user_name=#{user.username}",
                                               "cointhink_script_name=#{name}",
                                               "cointhink_script_key=#{key}"],
                                       "PortSpecs"=>["3002"]})
    logger.info "Script#build_container "+result.inspect
    result["Id"]
  end
end
