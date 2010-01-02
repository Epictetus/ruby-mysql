# Copyright (C) 2008-2010 TOMITA Masahiro
# mailto:tommy@tmtm.org

require "enumerator"
require "uri"

# MySQL connection class.
# === Example
#  Mysql.connect("mysql://user:password@hostname:port/dbname") do |my|
#    res = my.query "select col1,col2 from tbl where id=?", 123
#    res.each do |c1, c2|
#      p c1, c2
#    end
#  end
class Mysql

  dir = File.dirname __FILE__
  require "#{dir}/mysql/constants"
  require "#{dir}/mysql/error"
  require "#{dir}/mysql/charset"
  require "#{dir}/mysql/protocol"

  VERSION            = 20900               # Version number of this library
  MYSQL_UNIX_PORT    = "/tmp/mysql.sock"   # UNIX domain socket filename
  MYSQL_TCP_PORT     = 3306                # TCP socket port number

  attr_reader :charset               # character set of MySQL connection
  attr_reader :affected_rows         # number of affected records by insert/update/delete.
  attr_reader :server_status         # :nodoc:
  attr_reader :warning_count         # number of warnings for previous query
  attr_reader :protocol              # :nodoc:
  attr_reader :sqlstate              # sqlstate for latest query

  attr_accessor :query_with_result
  attr_accessor :reconnect

  class << self
    # Make Mysql object without connecting.
    def init
      my = self.allocate
      my.instance_eval{initialize}
      my
    end

    # Make Mysql object and connect to mysqld.
    # Arguments are same as Mysql#connect.
    def new(*args)
      my = self.init
      my.connect *args
    end

    alias real_connect new
    alias connect new

    # Escape special character in string.
    # === Argument
    # str :: [String]
    def escape_string(str)
      str.gsub(/[\0\n\r\\\'\"\x1a]/) do |s|
        case s
        when "\0" then "\\0"
        when "\n" then "\\n"
        when "\r" then "\\r"
        when "\x1a" then "\\Z"
        else "\\#{s}"
        end
      end
    end
    alias quote escape_string

    # Return client version as String.
    # This value is dummy.
    def client_info
      "5.0.0"
    end
    alias get_client_info client_info

    # Return client version as Integer
    # This value is dummy. If you want to get version of this library, use Mysql::VERSION.
    def client_version
      50000
    end
    alias get_client_version client_version
  end

  def initialize  # :nodoc:
    @fields = nil
    @protocol = nil
    @charset = nil
    @connect_timeout = nil
    @read_timeout = nil
    @write_timeout = nil
    @init_command = nil
    @affected_rows = nil
    @warning_count = 0
    @server_version = nil
    @sqlstate = "00000"
    @connected = false
    @query_with_result = true
    @reconnect = false
    @host_info = nil
    @info = nil
    @last_error = nil
    @thread_id = nil
    @result_exist = false
    @local_infile = nil
  end

  # Connect to mysqld.
  # === Argument
  # host   :: [String] hostname mysqld running
  # user   :: [String] username to connect to mysqld
  # passwd :: [String] password to connect to mysqld
  # db     :: [String] initial database name
  # port   :: [Integer] port number (used if host is not 'localhost' or nil)
  # socket :: [String] socket file name (used if host is 'localhost' or nil)
  # flag   :: [Integer] connection flag. Mysql::CLIENT_* ORed
  # === Return
  # self
  def connect(host=nil, user=nil, passwd=nil, db=nil, port=nil, socket=nil, flag=nil)
    @protocol = Protocol.new host, port, socket, @connect_timeout, @read_timeout, @write_timeout
    @protocol.synchronize do
      init_packet = @protocol.read_initial_packet
      @server_info = init_packet.server_version
      @server_version = init_packet.server_version.split(/\D/)[0,3].inject{|a,b|a.to_i*100+b.to_i}
      @thread_id = init_packet.thread_id
      client_flags = CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_TRANSACTIONS | CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION
      client_flags |= CLIENT_CONNECT_WITH_DB if db
      client_flags |= flag if flag
      client_flags |= CLIENT_LOCAL_FILES if @local_infile
      unless @charset
        @charset = Charset.by_number(init_packet.server_charset)
        @charset.encoding       # raise error if unsupported charset
      end
      netpw = init_packet.crypt_password passwd
      auth_packet = Protocol::AuthenticationPacket.new client_flags, 1024**3, @charset.number, user, netpw, db
      @protocol.send_packet auth_packet
      @protocol.read            # skip OK packet
    end
    @host_info = (host.nil? || host == "localhost") ? 'Localhost via UNIX socket' : "#{host} via TCP/IP"
    query @init_command if @init_command
    return self
  end
  alias real_connect connect

  # Disconnect from mysql.
  def close
    if @protocol
      @protocol.synchronize do
        @protocol.reset
        @protocol.send_packet Protocol::QuitPacket.new
        @protocol.close
        @protocol = nil
      end
    end
    return self
  end

  # Set option for connection.
  #
  # Available options:
  #   Mysql::INIT_COMMAND, Mysql::OPT_CONNECT_TIMEOUT, Mysql::OPT_READ_TIMEOUT,
  #   Mysql::OPT_RECONNECT, Mysql::OPT_WRITE_TIMEOUT, Mysql::SET_CHARSET_NAME
  # === Argument
  # opt   :: [Integer] option
  # value :: option value that is depend on opt
  # === Return
  # self
  def options(opt, value=nil)
    case opt
    when Mysql::INIT_COMMAND
      @init_command = value.to_s
#    when Mysql::OPT_COMPRESS
    when Mysql::OPT_CONNECT_TIMEOUT
      @connect_timeout = value
#    when Mysql::GUESS_CONNECTION
    when Mysql::OPT_LOCAL_INFILE
      @local_infile = value
#    when Mysql::OPT_NAMED_PIPE
#    when Mysql::OPT_PROTOCOL
    when Mysql::OPT_READ_TIMEOUT
      @read_timeout = value.to_i
    when Mysql::OPT_RECONNECT
      @reconnect = value
#    when Mysql::SET_CLIENT_IP
#    when Mysql::OPT_SSL_VERIFY_SERVER_CERT
#    when Mysql::OPT_USE_EMBEDDED_CONNECTION
#    when Mysql::OPT_USE_REMOTE_CONNECTION
    when Mysql::OPT_WRITE_TIMEOUT
      @write_timeout = value.to_i
#    when Mysql::READ_DEFAULT_FILE
#    when Mysql::READ_DEFAULT_GROUP
#    when Mysql::REPORT_DATA_TRUNCATION
#    when Mysql::SECURE_AUTH
#    when Mysql::SET_CHARSET_DIR
    when Mysql::SET_CHARSET_NAME
      @charset = Charset.by_name value.to_s
#    when Mysql::SHARED_MEMORY_BASE_NAME
    else
      warn "option not implemented: #{opt}"
    end
    self
  end

  # Escape special character in MySQL.
  # === Note
  # In Ruby 1.8, this is not safe for multibyte charset such as 'SJIS'.
  # You should use place-holder in prepared-statement.
  def escape_string(str)
    str.gsub(/[\0\n\r\\\'\"\x1a]/) do |s|
      case s
      when "\0" then "\\0"
      when "\n" then "\\n"
      when "\r" then "\\r"
      when "\x1a" then "\\Z"
      else "\\#{s}"
      end
    end
  end
  alias quote escape_string

  def client_info
    self.class.client_info
  end
  alias get_client_info client_info

  def client_version
    self.class.client_version
  end
  alias get_client_version client_version

  # Set charset of MySQL connection.
  # === Argument
  # cs :: [String / Mysql::Charset]
  # === Return
  # cs
  def charset=(cs)
    charset = cs.is_a?(Charset) ? cs : Charset.by_name(cs)
    query "SET NAMES #{charset.name}" if @protocol
    @charset = charset
    cs
  end

  # Return charset name
  def character_set_name
    @charset.name
  end

  # Create database
  # === Argument
  # db :: [String] database name
  # === Return
  # self
  def create_db(db)
    query "create database #{db}"
    self
  end

  # Drop database.
  # === Argument
  # db :: [String] database name
  # === Return
  # self
  def drop_db(db)
    query "drop database #{db}"
    self
  end

  # Return last error number.
  # === Return
  # [Integer]
  def errno
    @last_error && @last_error.errno
  end

  # Return last error message.
  # === Return
  # [String]
  def error
    @last_error && @last_error.error
  end

  # Return number of columns for last query.
  # === Return
  # [Integer]
  def field_count
    @fields.size
  end

  # Return connection type.
  # === Return
  # [String]
  def host_info
    @host_info
  end
  alias get_host_info host_info

  # Return protocol version.
  # === Return
  # [Integer]
  def proto_info
    Mysql::Protocol::VERSION
  end
  alias get_proto_info proto_info

  # Return server version as String
  # === Return
  # [String]
  def server_info
    @server_info
  end
  alias get_server_info server_info

  # Return server version as Integer
  def server_version
    @server_version
  end
  alias get_server_version server_version

  # Return information for last query.
  # === Return
  # [String]
  def info
    @info
  end

  # Return latest auto_increment value.
  # === Return
  # [Integer]
  def insert_id
    @insert_id
  end

  # Kill query.
  # === Argument
  # pid :: [Integer] thread id
  # === Return
  # self
  def kill(pid)
    query "kill #{pid}"
    self
  end

  # Return database list.
  #
  # NOTE for Ruby 1.8: This is not multi-byte safe. Don't use for
  # multi-byte charset such as cp932.
  # === Argument
  # db :: [String] database name that may contain wild card.
  # === Return
  # [Array of String] database list
  def list_dbs(db=nil)
    query(db ? "show databases like '#{quote db}'" : "show databases").map(&:first)
  end

  # Execute query string.
  # === Argument
  # str :: [String] Query.
  # block :: If it is given then it is evaluated with Result object as argument.
  # === Return
  # Mysql::Result :: If result set exist.
  # nil :: If the query does not return result set.
  # self :: If block is specified.
  # === Block parameter
  # [ Mysql::Result ]
  # === Example
  #  my.query("select 1,NULL,'abc'").fetch  # => [1, nil, "abc"]
  def query(str, &block)
    unless block
      ret = simple_query str, @query_with_result
      return @query_with_result ? ret : self
    end
    simple_query str, false
    while true
      if @fields
        res = store_result
        block.call res
      end
      break unless next_result
    end
    self
  end
  alias real_query query

  def simple_query(str, query_with_result)  # :nodoc:
    @affected_rows = @insert_id = @server_status = @warning_count = 0
    @protocol.synchronize do
      begin
        @protocol.reset
        @protocol.send_packet Protocol::QueryPacket.new(@charset.convert(str))
        res_packet = @protocol.read_result_packet
        if res_packet.field_count == 0
          @affected_rows, @insert_id, @server_status, @warning_count, @info =
            res_packet.affected_rows, res_packet.insert_id, res_packet.server_status, res_packet.warning_count, res_packet.message
          return nil
        end
        if res_packet.field_count.nil?   # LOAD DATA LOCAL INFILE
          filename = res_packet.message
          @protocol.write File.read(filename)
          @protocol.write nil  # EOF mark
          @protocol.read
          @affected_rows, @insert_id, @server_status, @warning_count, @info =
            res_packet.affected_rows, res_packet.insert_id, res_packet.server_status, res_packet.warning_count, res_packet.message
          return nil
        end
        @fields = Array.new(res_packet.field_count).map{Field.new @protocol.read_field_packet}
        @protocol.read_eof_packet
        @result_exist = true
        return store_result if query_with_result
      rescue ServerError => e
        @last_error = e
        @sqlstate = e.sqlstate
        raise
      end
    end
  end

  # Get all data for last query if query_with_result is false.
  # === Return
  # [Mysql::Result]
  def store_result
    raise ClientError, 'invalid usage' unless @result_exist
    res = SimpleQueryResult.new self, @fields
    @server_status = res.server_status
    @result_exist = false
    res
  end

  # Returns thread ID.
  # === Return
  # [Integer] Thread ID
  def thread_id
    @thread_id
  end

  # Use result of query. The result data is retrieved when you use Mysql::Result#fetch_row
  def use_result
    store_result
  end

  def set_server_option(opt)
    @protocol.synchronize do
      @protocol.reset
      @protocol.send_packet Protocol::SetOptionPacket.new(opt)
      @protocol.read_eof_packet
    end
    self
  end

  def more_results
    @server_status & SERVER_MORE_RESULTS_EXISTS != 0
  end
  alias more_results? more_results

  def next_result
    return false unless more_results
    res_packet = @protocol.read_result_packet
    if res_packet.field_count == 0
      @affected_rows, @insert_id, @server_status, @warning_conut =
        res_packet.affected_rows, res_packet.insert_id, res_packet.server_status, res_packet.warning_count
      @fields = nil
    else
      @fields = Array.new(res_packet.field_count).map{Field.new @protocol.read_field_packet}
      @protocol.read_eof_packet
    end
    @result_exist = true
    return true
  end

  # Parse prepared-statement.
  # === Argument
  # str   :: [String] query string
  # === Return
  # Mysql::Statement :: Prepared-statement object
  def prepare(str)
    st = Stmt.new self
    st.prepare str
    st
  end

  # Make empty prepared-statement object.
  # === Return
  # Mysql::Stmt :: If block is not specified.
  def stmt_init
    Stmt.new self
  end

  # Returns Mysql::Result object that is empty.
  # Use fetch_fields to get list of fields.
  # === Argument
  # table :: [String] table name.
  # field :: [String] field name that may contain wild card.
  # === Return
  # [Mysql::Result]
  def list_fields(table, field=nil)
    @protocol.synchronize do
      begin
        @protocol.reset
        @protocol.send_packet Protocol::FieldListPacket.new(table, field)
        fields = []
        until Protocol.eof_packet?(data = @protocol.read)
          fields.push Field.new(Protocol::FieldPacket.parse(data))
        end
        res = Result.allocate
        res.instance_variable_set(:@fields, fields)
        res.instance_variable_set(:@records, [])
        res.instance_variable_set(:@index, 0)
        res.instance_variable_set(:@field_index, 0)
        return res
      rescue ServerError => e
        @last_error = e
        @sqlstate = e.sqlstate
        raise
      end
    end
  end

  # Returns Mysql::Result object containing process list.
  # === Return
  # [Mysql::Result]
  def list_processes
    @protocol.reset
    @protocol.send_packet Protocol::ProcessInfoPacket.new
    field_count = Protocol.lcb2int!(@protocol.read)
    @fields = Array.new(field_count).map{Field.new @protocol.read_field_packet}
    @protocol.read_eof_packet
    @result_exist = true
    store_result
  end

  # Returns list of table name.
  #
  # NOTE for Ruby 1.8: This is not multi-byte safe. Don't use for
  # multi-byte charset such as cp932.
  # === Argument
  # table :: [String] database name that may contain wild card.
  # === Return
  # [Array of String]
  def list_tables(table=nil)
    query(table ? "show tables like '#{quote table}'" : "show tables").map(&:first)
  end

  # Check whether the  connection is available.
  # === Return
  # self
  def ping
    @protocol.reset
    @protocol.send_packet Protocol::PingPacket.new
    @protocol.read
    self
  end

  # Flush tables or caches.
  # === Argument
  # op :: [Integer] operation. Use Mysql::REFRESH_* value.
  # === Return
  # self
  def refresh(op)
    @protocol.reset
    @protocol.send_packet Protocol::RefreshPacket.new(op)
    @protocol.read
    self
  end

  # Reload grant tables.
  # === Return
  # self
  def reload
    refresh Mysql::REFRESH_GRANT
  end

  # Select default database
  # === Return
  # self
  def select_db(db)
    query "use #{db}"
    self
  end

  def shutdown(level)
    raise 'not implemented'
  end

  def stat
    @protocol.reset
    @protocol.send_packet Protocol::StatisticsPacket.new
    @protocol.read
  end

  def commit
    query 'commit'
    self
  end

  def rollback
    query 'rollback'
    self
  end

  def autocommit(flag)
    query "set autocommit=#{flag ? 1 : 0}"
    self
  end

  private

  # analyze argument and returns connection-parameter and option.
  #
  # connection-parameter's key :: :host, :user, :password, :db, :port, :socket, :flag
  # === Return
  # Hash :: connection parameters
  # Hash :: option {:optname => value, ...}
  def conninfo(*args)
    paramkeys = [:host, :user, :password, :db, :port, :socket, :flag]
    opt = {}
    if args.empty?
      param = {}
    elsif args.size == 1 and args.first.is_a? Hash
      arg = args.first.dup
      param = {}
      [:host, :user, :password, :db, :port, :socket, :flag].each do |k|
        param[k] = arg.delete k if arg.key? k
      end
      opt = arg
    else
      if args.last.is_a? Hash
        args = args.dup
        opt = args.pop
      end
      if args.size > 1 || args.first.nil? || args.first.is_a?(String) && args.first !~ /\Amysql:/
        host, user, password, db, port, socket, flag = args
        param = {:host=>host, :user=>user, :password=>password, :db=>db, :port=>port, :socket=>socket, :flag=>flag}
      elsif args.first.is_a? Hash
        param = args.first.dup
        param.keys.each do |k|
          unless paramkeys.include? k
            raise ArgumentError, "Unknown parameter: #{k.inspect}"
          end
        end
      else
        if args.first =~ /\Amysql:/
          uri = URI.parse args.first
        elsif args.first.is_a? URI
          uri = args.first
        else
          raise ArgumentError, "Invalid argument: #{args.first.inspect}"
        end
        unless uri.scheme == "mysql"
          raise ArgumentError, "Invalid scheme: #{uri.scheme}"
        end
        param = {:host=>uri.host, :user=>uri.user, :password=>uri.password, :port=>uri.port||MYSQL_TCP_PORT}
        param[:db] = uri.path.split(/\/+/).reject{|a|a.empty?}.first
        if uri.query
          uri.query.split(/\&/).each do |a|
            k, v = a.split(/\=/, 2)
            if k == "socket"
              param[:socket] = v
            elsif k == "flag"
              param[:flag] = v.to_i
            else
              opt[k.intern] = v
            end
          end
        end
      end
    end
    param[:flag] = 0 unless param.key? :flag
    opt.keys.each do |k|
      if OPT2FLAG.key? k and opt[k]
        param[:flag] |= OPT2FLAG[k]
        next
      end
      unless OPTIONS.key? k
        raise ArgumentError, "Unknown option: #{k.inspect}"
      end
      opt[k] = opt[k].to_i if OPTIONS[k] == Integer
    end
    return param, opt
  end

  def set_option(opt)
    opt.each do |k,v|
      raise ClientError, "unknown option: #{k.inspect}" unless OPTIONS.key? k
      type = OPTIONS[k]
      if type.is_a? Class
        raise ClientError, "invalid value for #{k.inspect}: #{v.inspect}" unless v.is_a? type
      end
    end

    charset = opt[:charset] if opt.key? :charset
    @connect_timeout = opt[:connect_timeout] || @connect_timeout
    @init_command = opt[:init_command] || @init_command
    @read_timeout = opt[:read_timeout] || @read_timeout
    @write_timeout = opt[:write_timeout] || @write_timeout
  end

  # Field class
  class Field
    attr_reader :db             # database name
    attr_reader :table          # table name
    attr_reader :org_table      # original table name
    attr_reader :name           # field name
    attr_reader :org_name       # original field name
    attr_reader :charsetnr      # charset id number
    attr_reader :length         # field length
    attr_reader :type           # field type
    attr_reader :flags          # flag
    attr_reader :decimals       # number of decimals
    attr_reader :default        # defualt value
    alias :def :default
    attr_accessor :max_length   # maximum width of the field for the result set

    # === Argument
    # packet :: [Protocol::FieldPacket]
    def initialize(packet)
      @db, @table, @org_table, @name, @org_name, @charsetnr, @length, @type, @flags, @decimals, @default =
        packet.db, packet.table, packet.org_table, packet.name, packet.org_name, packet.charsetnr, packet.length, packet.type, packet.flags, packet.decimals, packet.default
      @flags |= NUM_FLAG if is_num_type?
    end

    def hash
      {
        "name"       => @name,
        "table"      => @table,
        "def"        => @default,
        "type"       => @type,
        "length"     => @length,
        "max_length" => @max_length,
        "flags"      => @flags,
        "decimals"   => @decimals
      }
    end

    def inspect
      "#<Mysql::Field:#{@name}>"
    end

    # Return true if numeric field.
    def is_num?
      @flags & NUM_FLAG != 0
    end

    # Return true if not null field.
    def is_not_null?
      @flags & NOT_NULL_FLAG != 0
    end

    # Return true if primary key field.
    def is_pri_key?
      @flags & PRI_KEY_FLAG != 0
    end

    private

    def is_num_type?
      [TYPE_DECIMAL, TYPE_TINY, TYPE_SHORT, TYPE_LONG, TYPE_FLOAT, TYPE_DOUBLE, TYPE_LONGLONG, TYPE_INT24].include?(@type) || (@type == TYPE_TIMESTAMP && (@length == 14 || @length == 8))
    end

  end

  # Result set
  class Result
    include Enumerable

    attr_reader :fields

    def initialize(mysql, fields)
      @fields = fields
      @fieldname_with_table = nil
      @index = 0
      @records = recv_all_records mysql.protocol, fields, mysql.charset
      @field_index = 0
    end

    def free
    end

    def size
      @records.size
    end

    def fetch_row
      @fetched_record = nil
      return nil if @index >= @records.size
      rec = @records[@index]
      @index += 1
      @fetched_record = rec
      return rec
    end

    alias fetch fetch_row

    def fetch_hash(with_table=nil)
      row = fetch_row
      return nil unless row
      if with_table and @fieldname_with_table.nil?
        @fieldname_with_table = @fields.map{|f| [f.table, f.name].join(".")}
      end
      ret = {}
      @fields.each_index do |i|
        fname = with_table ? @fieldname_with_table[i] : @fields[i].name
        ret[fname] = row[i]
      end
      ret
    end

    def each(&block)
      return enum_for(:each) unless block
      while rec = fetch_row
        block.call rec
      end
      self
    end

    def each_hash(with_table=nil, &block)
      return enum_for(:each_hash, with_table) unless block
      while rec = fetch_hash(with_table)
        block.call rec
      end
      self
    end

    def num_rows
      @records.size
    end

    def data_seek(n)
      @index = n
    end

    def row_tell
      @index
    end

    def row_seek(n)
      ret = @index
      @index = n
      ret
    end

    def fetch_field
      return nil if @field_index >= @fields.length
      ret = @fields[@field_index]
      @field_index += 1
      ret
    end

    def field_tell
      @field_index
    end

    def field_seek(n)
      @field_index = n
    end

    def fetch_field_direct(n)
      raise ClientError, "invalid argument: #{n}" if n < 0 or n >= @fields.length
      @fields[n]
    end

    def fetch_fields
      @fields
    end

    def fetch_lengths
      return nil unless @fetched_record
      @fetched_record.map{|c|c.nil? ? 0 : c.length}
    end

    def num_fields
      @fields.size
    end
  end

  # Result set for simple query
  class SimpleQueryResult < Result

    attr_reader :server_status

    private

    def recv_all_records(protocol, fields, charset)
      ret = []
      while true
        data = protocol.read
        break if Protocol.eof_packet? data
        rec = fields.map do |f|
          v = Protocol.lcs2str! data
          f.max_length = [v ? v.length : 0, f.max_length || 0].max
          v
        end
        ret.push rec
      end
      @server_status = data[3].ord
      ret
    end
  end

  # Result set for prepared statement
  class StatementResult < Result

    private

    def recv_all_records(protocol, fields, charset)
      ret = []
      while rec = parse_data(protocol.read, fields, charset)
        ret.push rec
      end
      ret
    end

    def parse_data(data, fields, charset)
      return nil if Protocol.eof_packet? data
      data.slice!(0)  # skip first byte
      null_bit_map = data.slice!(0, (fields.length+7+2)/8).unpack("b*").first
      ret = fields.each_with_index.map do |f, i|
        if null_bit_map[i+2] == ?1
          nil
        else
          unsigned = f.flags & Field::UNSIGNED_FLAG != 0
          v = Protocol.net2value(data, f.type, unsigned)
          if v.is_a? Numeric or v.is_a? Mysql::Time
            v
          elsif f.type == Field::TYPE_BIT or f.flags & Field::BINARY_FLAG != 0
            Charset.to_binary(v)
          else
            charset.force_encoding(v)
          end
        end
      end
      ret
    end
  end

  # Prepared statement
  class Stmt
    include Enumerable

    attr_reader :affected_rows, :insert_id, :server_status, :warning_count
    attr_reader :param_count, :fields, :sqlstate

    def self.finalizer(protocol, statement_id)
      proc do
        Thread.new do
          protocol.synchronize do
            protocol.reset
            protocol.send_packet Protocol::StmtClosePacket.new(statement_id)
          end
        end
      end
    end

    def initialize(mysql)
      @mysql = mysql
      @protocol = mysql.protocol
      @statement_id = nil
      @affected_rows = @insert_id = @server_status = @warning_count = 0
      @sqlstate = "00000"
      @param_count = nil
    end

    # parse prepared-statement and return Mysql::Statement object
    # === Argument
    # str :: [String] query string
    # === Return
    # self
    def prepare(str)
      close
      @protocol.synchronize do
        begin
          @sqlstate = "00000"
          @protocol.reset
          @protocol.send_packet Protocol::PreparePacket.new(@mysql.charset.convert(str))
          res_packet = @protocol.read_prepare_result_packet
          if res_packet.param_count > 0
            res_packet.param_count.times{@protocol.read}   # skip parameter packet
            @protocol.read_eof_packet
          end
          if res_packet.field_count > 0
            fields = Array.new(res_packet.field_count).map{Field.new @protocol.read_field_packet}
            @protocol.read_eof_packet
          else
            fields = []
          end
          @statement_id = res_packet.statement_id
          @param_count = res_packet.param_count
          @fields = fields
        rescue ServerError => e
          @last_error = e
          @sqlstate = e.sqlstate
          raise
        end
      end
      ObjectSpace.define_finalizer(self, self.class.finalizer(@protocol, @statement_id))
      self
    end

    # execute prepared-statement.
    # === Return
    # Mysql::Result
    def execute(*values)
      raise ClientError, "not prepared" unless @param_count
      raise ClientError, "parameter count mismatch" if values.length != @param_count
      values = values.map{|v| @mysql.charset.convert v}
      @protocol.synchronize do
        begin
          @sqlstate = "00000"
          @protocol.reset
          @protocol.send_packet Protocol::ExecutePacket.new(@statement_id, CURSOR_TYPE_NO_CURSOR, values)
          res_packet = @protocol.read_result_packet
          raise ProtocolError, "invalid field_count" unless res_packet.field_count == @fields.length
          @fieldname_with_table = nil
          if res_packet.field_count == 0
            @affected_rows, @insert_id, @server_status, @warning_conut =
              res_packet.affected_rows, res_packet.insert_id, res_packet.server_status, res_packet.warning_count
            @result = nil
            return self
          end
          @fields = Array.new(res_packet.field_count).map{Field.new @protocol.read_field_packet}
          @protocol.read_eof_packet
          @result = StatementResult.new(@mysql, @fields)
          return self
        rescue ServerError => e
          @last_error = e
          @sqlstate = e.sqlstate
          raise
        end
      end
    end

    def close
      ObjectSpace.undefine_finalizer(self)
      @protocol.synchronize do
        @protocol.reset
        if @statement_id
          @protocol.send_packet Protocol::StmtClosePacket.new(@statement_id)
          @statement_id = nil
        end
      end
    end

    def fetch
      row = @result.fetch_row
      return row if @bind_result.nil?
      row.enum_for(:each_with_index).map do |col, i|
        if col.nil?
          nil
        elsif [Numeric, Integer, Fixnum].include? @bind_result[i]
          col.to_i
        elsif @bind_result[i] == String
          col.to_s
        elsif @bind_result[i] == Float && !col.is_a?(Float)
          col.to_i.to_f
        elsif @bind_result[i] == Mysql::Time && !col.is_a?(Mysql::Time)
          if col.to_s =~ /\A\d+\z/
            i = col.to_s.to_i
            if i < 100000000
              y = i/10000
              m = i/100%100
              d = i%100
              h, mm, s = 0
            else
              y = i/10000000000
              m = i/100000000%100
              d = i/1000000%100
              h = i/10000%100
              mm= i/100%100
              s = i%100
            end
            if y < 70
              y += 2000
            elsif y < 100
              y += 1900
            end
            Mysql::Time.new(y, m, d, h, mm, s)
          else
            Mysql::Time.new
          end
        else
          col
        end
      end
    end

    def fetch_hash
      @result.fetch_hash
    end

    def bind_result(*args)
      if @fields.length != args.length
        raise ClientError, "bind_result: result value count(#{@fields.length}) != number of argument(#{args.length})"
      end
      args.each do |a|
        raise TypeError unless [Numeric, Fixnum, Integer, Float, String, Mysql::Time, nil].include? a
      end
      @bind_result = args
      self
    end

    def each(&block)
      return enum_for(:each) unless block
      while rec = fetch
        block.call rec
      end
      self
    end

    def each_hash(with_table=nil, &block)
      return enum_for(:each_hash, with_table) unless block
      while rec = fetch_hash(with_table)
        block.call rec
      end
      self
    end

    def num_rows
      @result.num_rows
    end

    def data_seek(n)
      @result.data_seek(n)
    end

    def row_tell
      @result.row_tell
    end

    def row_seek(n)
      @result.row_seek(n)
    end

    def field_count
      @fields.length
    end

    def free_result
      # do nothing
    end

    def result_metadata
      return nil if @fields.empty?
      res = Result.allocate
      res.instance_variable_set :@mysql, @mysql
      res.instance_variable_set :@fields, @fields
      res.instance_variable_set :@records, []
      res
    end
  end

  class Time
    def initialize(year=0, month=0, day=0, hour=0, minute=0, second=0, neg=false, second_part=0)
      @year, @month, @day, @hour, @minute, @second, @neg, @second_part =
        year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, second.to_i, neg, second_part.to_i
    end
    attr_accessor :year, :month, :day, :hour, :minute, :second, :neg, :second_part
    alias mon month
    alias min minute
    alias sec second

    def ==(other)
      other.is_a?(Mysql::Time) &&
        @year == other.year && @month == other.month && @day == other.day &&
        @hour == other.hour && @minute == other.minute && @second == other.second &&
        @neg == neg && @second_part == other.second_part
    end

    def eql?(other)
      self == other
    end

    def to_s
      if year == 0 and mon == 0 and day == 0
        h = neg ? hour * -1 : hour
        sprintf "%02d:%02d:%02d", h, min, sec
      else
        sprintf "%04d-%02d-%02d %02d:%02d:%02d", year, mon, day, hour, min, sec
      end
    end

    def to_i
      sprintf("%04d%02d%02d%02d%02d%02d", year, mon, day, hour, min, sec).to_i
    end

    def inspect
      sprintf "#<#{self.class.name}:%04d-%02d-%02d %02d:%02d:%02d>", year, mon, day, hour, min, sec
    end

  end

end
