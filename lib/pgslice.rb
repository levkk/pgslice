# dependencies
require "cgi"
require "slop"
require "pg"

# modules
require "pgslice/table"
require "pgslice/version"

module PgSlice
  class Error < StandardError; end

  class Client
    attr_reader :arguments, :options

    SQL_FORMAT = {
      day: "YYYYMMDD",
      month: "YYYYMM"
    }

    def initialize(args)
      $stdout.sync = true
      $stderr.sync = true
      parse_args(args)
      @command = @arguments.shift
    end

    def perform
      $client = self

      return if @exit

      case @command
      when "prep"
        prep
      when "add_partitions"
        add_partitions
      when "fill"
        fill
      when "swap"
        swap
      when "unswap"
        unswap
      when "unprep"
        unprep
      when "analyze"
        analyze
      when nil
        log "Commands: add_partitions, analyze, fill, prep, swap, unprep, unswap"
      else
        abort "Unknown command: #{@command}"
      end
    ensure
      @connection.close if @connection
    end

    protected

    # commands

    def prep
      table, column, period = arguments
      table = Table.new(qualify_table(table))
      intermediate_table = table.intermediate_table

      trigger_name = table.trigger_name

      if options[:no_partition]
        abort "Usage: pgslice prep <table> --no-partition" if arguments.length != 1
        abort "Can't use --trigger-based and --no-partition" if options[:trigger_based]
      else
        abort "Usage: pgslice prep <table> <column> <period>" if arguments.length != 3
      end
      abort "Table not found: #{table}" unless table.exists?
      abort "Table already exists: #{intermediate_table}" if intermediate_table.exists?

      unless options[:no_partition]
        abort "Column not found: #{column}" unless table.columns.include?(column)
        abort "Invalid period: #{period}" unless SQL_FORMAT[period.to_sym]
      end

      queries = []

      declarative = server_version_num >= 100000 && !options[:trigger_based]

      if declarative && !options[:no_partition]
        queries << <<-SQL
CREATE TABLE #{quote_table(intermediate_table)} (LIKE #{quote_table(table)} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING STORAGE INCLUDING COMMENTS) PARTITION BY RANGE (#{quote_table(column)});
        SQL

        if server_version_num >= 110000
          index_defs = execute("SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = #{regclass(table)} AND indisprimary = 'f'").map { |r| r["pg_get_indexdef"] }
          index_defs.each do |index_def|
            queries << index_def.sub(/ ON \S+ USING /, " ON #{quote_table(intermediate_table)} USING ").sub(/ INDEX .+ ON /, " INDEX ON ") + ";"
          end
        end

        # add comment
        cast = table.column_cast(column)
        queries << <<-SQL
COMMENT ON TABLE #{quote_table(intermediate_table)} is 'column:#{column},period:#{period},cast:#{cast}';
        SQL
      else
        queries << <<-SQL
CREATE TABLE #{quote_table(intermediate_table)} (LIKE #{quote_table(table)} INCLUDING ALL);
        SQL

        table.foreign_keys.each do |fk_def|
          queries << "ALTER TABLE #{quote_table(intermediate_table)} ADD #{fk_def};"
        end
      end

      if !options[:no_partition] && !declarative
        queries << <<-SQL
CREATE FUNCTION #{quote_ident(trigger_name)}()
    RETURNS trigger AS $$
    BEGIN
        RAISE EXCEPTION 'Create partitions first.';
    END;
    $$ LANGUAGE plpgsql;
        SQL

        queries << <<-SQL
CREATE TRIGGER #{quote_ident(trigger_name)}
    BEFORE INSERT ON #{quote_table(intermediate_table)}
    FOR EACH ROW EXECUTE PROCEDURE #{quote_ident(trigger_name)}();
        SQL

        cast = table.column_cast(column)
        queries << <<-SQL
COMMENT ON TRIGGER #{quote_ident(trigger_name)} ON #{quote_table(intermediate_table)} is 'column:#{column},period:#{period},cast:#{cast}';
        SQL
      end

      run_queries(queries)
    end

    def unprep
      table = qualify_table(arguments.first)
      intermediate_table = "#{table}_intermediate"
      trigger_name = self.trigger_name(table)

      abort "Usage: pgslice unprep <table>" if arguments.length != 1
      abort "Table not found: #{intermediate_table}" unless table_exists?(intermediate_table)

      queries = [
        "DROP TABLE #{quote_table(intermediate_table)} CASCADE;",
        "DROP FUNCTION IF EXISTS #{quote_ident(trigger_name)}();"
      ]
      run_queries(queries)
    end

    def add_partitions
      original_table = qualify_table(arguments.first)
      table = options[:intermediate] ? "#{original_table}_intermediate" : original_table
      trigger_name = self.trigger_name(original_table)

      abort "Usage: pgslice add_partitions <table>" if arguments.length != 1
      abort "Table not found: #{table}" unless table_exists?(table)

      future = options[:future]
      past = options[:past]
      range = (-1 * past)..future

      period, field, cast, needs_comment, declarative = settings_from_trigger(original_table, table)
      unless period
        message = "No settings found: #{table}"
        message = "#{message}\nDid you mean to use --intermediate?" unless options[:intermediate]
        abort message
      end

      queries = []

      if needs_comment
        queries << "COMMENT ON TRIGGER #{quote_ident(trigger_name)} ON #{quote_table(table)} is 'column:#{field},period:#{period},cast:#{cast}';"
      end

      # today = utc date
      today = round_date(DateTime.now.new_offset(0).to_date, period)

      schema_table =
        if !declarative
          table
        elsif options[:intermediate]
          original_table
        else
          existing_partitions(original_table, period).last
        end

      # indexes automatically propagate in Postgres 11+
      index_defs =
        if !declarative || server_version_num < 110000
          execute("SELECT pg_get_indexdef(indexrelid) FROM pg_index WHERE indrelid = #{regclass(schema_table)} AND indisprimary = 'f'").map { |r| r["pg_get_indexdef"] }
        else
          []
        end

      fk_defs = foreign_keys(schema_table)
      primary_key = self.primary_key(schema_table)

      added_partitions = []
      range.each do |n|
        day = advance_date(today, period, n)

        partition_name = "#{original_table}_#{day.strftime(name_format(period))}"
        next if table_exists?(partition_name)
        added_partitions << partition_name

        if declarative
          queries << <<-SQL
CREATE TABLE #{quote_table(partition_name)} PARTITION OF #{quote_table(table)} FOR VALUES FROM (#{sql_date(day, cast, false)}) TO (#{sql_date(advance_date(day, period, 1), cast, false)});
          SQL
        else
          queries << <<-SQL
CREATE TABLE #{quote_table(partition_name)}
    (CHECK (#{quote_ident(field)} >= #{sql_date(day, cast)} AND #{quote_ident(field)} < #{sql_date(advance_date(day, period, 1), cast)}))
    INHERITS (#{quote_table(table)});
          SQL
        end

        queries << "ALTER TABLE #{quote_table(partition_name)} ADD PRIMARY KEY (#{primary_key.map { |k| quote_ident(k) }.join(", ")});" if primary_key.any?

        index_defs.each do |index_def|
          queries << index_def.sub(/ ON \S+ USING /, " ON #{quote_table(partition_name)} USING ").sub(/ INDEX .+ ON /, " INDEX ON ") + ";"
        end

        fk_defs.each do |fk_def|
          queries << "ALTER TABLE #{quote_table(partition_name)} ADD #{fk_def};"
        end
      end

      unless declarative
        # update trigger based on existing partitions
        current_defs = []
        future_defs = []
        past_defs = []
        name_format = self.name_format(period)
        existing_tables = existing_partitions(original_table, period)
        existing_tables = (existing_tables + added_partitions).uniq.sort

        existing_tables.each do |existing_table|
          day = DateTime.strptime(existing_table.split("_").last, name_format)
          partition_name = "#{original_table}_#{day.strftime(name_format(period))}"

          sql = "(NEW.#{quote_ident(field)} >= #{sql_date(day, cast)} AND NEW.#{quote_ident(field)} < #{sql_date(advance_date(day, period, 1), cast)}) THEN
              INSERT INTO #{quote_table(partition_name)} VALUES (NEW.*);"

          if day.to_date < today
            past_defs << sql
          elsif advance_date(day, period, 1) < today
            current_defs << sql
          else
            future_defs << sql
          end
        end

        # order by current period, future periods asc, past periods desc
        trigger_defs = current_defs + future_defs + past_defs.reverse

        if trigger_defs.any?
          queries << <<-SQL
CREATE OR REPLACE FUNCTION #{quote_ident(trigger_name)}()
    RETURNS trigger AS $$
    BEGIN
        IF #{trigger_defs.join("\n        ELSIF ")}
        ELSE
            RAISE EXCEPTION 'Date out of range. Ensure partitions are created.';
        END IF;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
          SQL
        end
      end

      run_queries(queries) if queries.any?
    end

    def fill
      table = Table.new(qualify_table(arguments.first))

      abort "Usage: pgslice fill <table>" if arguments.length != 1

      source_table = Table.new(options[:source_table]) if options[:source_table]
      dest_table = Table.new(options[:dest_table]) if options[:dest_table]

      if options[:swapped]
        source_table ||= table.retired_table
        dest_table ||= table
      else
        source_table ||= table
        dest_table ||= table.intermediate_table
      end

      abort "Table not found: #{source_table}" unless source_table.exists?
      abort "Table not found: #{dest_table}" unless dest_table.exists?

      period, field, cast, _needs_comment, declarative = settings_from_trigger(table, dest_table)

      if period
        name_format = self.name_format(period)

        existing_tables = table.existing_partitions(period)
        if existing_tables.any?
          starting_time = DateTime.strptime(existing_tables.first.split("_").last, name_format)
          ending_time = advance_date(DateTime.strptime(existing_tables.last.split("_").last, name_format), period, 1)
        end
      end

      schema_table = period && declarative ? Table.new(existing_tables.last) : table

      primary_key = schema_table.primary_key[0]
      abort "No primary key" unless primary_key

      max_source_id = nil
      begin
        max_source_id = source_table.max_id(primary_key)
      rescue PG::UndefinedFunction
        abort "Only numeric primary keys are supported"
      end

      max_dest_id =
        if options[:start]
          options[:start]
        elsif options[:swapped]
          dest_table.max_id(primary_key, where: options[:where], below: max_source_id)
        else
          dest_table.max_id(primary_key, where: options[:where])
        end

      if max_dest_id == 0 && !options[:swapped]
        min_source_id = source_table.min_id(primary_key, field, cast, starting_time, options[:where])
        max_dest_id = min_source_id - 1 if min_source_id
      end

      starting_id = max_dest_id
      fields = source_table.columns.map { |c| quote_ident(c) }.join(", ")
      batch_size = options[:batch_size]

      i = 1
      batch_count = ((max_source_id - starting_id) / batch_size.to_f).ceil

      if batch_count == 0
        log_sql "/* nothing to fill */"
      end

      while starting_id < max_source_id
        where = "#{quote_ident(primary_key)} > #{starting_id} AND #{quote_ident(primary_key)} <= #{starting_id + batch_size}"
        if starting_time
          where << " AND #{quote_ident(field)} >= #{sql_date(starting_time, cast)} AND #{quote_ident(field)} < #{sql_date(ending_time, cast)}"
        end
        if options[:where]
          where << " AND #{options[:where]}"
        end

        query = <<-SQL
/* #{i} of #{batch_count} */
INSERT INTO #{quote_table(dest_table)} (#{fields})
    SELECT #{fields} FROM #{quote_table(source_table)}
    WHERE #{where}
        SQL

        run_query(query)

        starting_id += batch_size
        i += 1

        if options[:sleep] && starting_id <= max_source_id
          sleep(options[:sleep])
        end
      end
    end

    def swap
      table = Table.new(qualify_table(arguments.first))
      intermediate_table = table.intermediate_table
      retired_table = table.retired_table

      abort "Usage: pgslice swap <table>" if arguments.length != 1
      abort "Table not found: #{table}" unless table.exists?
      abort "Table not found: #{intermediate_table}" unless intermediate_table.exists?
      abort "Table already exists: #{retired_table}" if retired_table.exists?

      queries = [
        "ALTER TABLE #{quote_table(table)} RENAME TO #{quote_no_schema(retired_table)};",
        "ALTER TABLE #{quote_table(intermediate_table)} RENAME TO #{quote_no_schema(table)};"
      ]

      table.sequences.each do |sequence|
        queries << "ALTER SEQUENCE #{quote_ident(sequence["sequence_name"])} OWNED BY #{quote_table(table)}.#{quote_ident(sequence["related_column"])};"
      end

      queries.unshift("SET LOCAL lock_timeout = '#{options[:lock_timeout]}';") if server_version_num >= 90300

      run_queries(queries)
    end

    def unswap
      table = Table.new(qualify_table(arguments.first))
      intermediate_table = table.intermediate_table
      retired_table = table.retired_table

      abort "Usage: pgslice unswap <table>" if arguments.length != 1
      abort "Table not found: #{table}" unless table.exists?
      abort "Table not found: #{retired_table}" unless retired_table.exists?
      abort "Table already exists: #{intermediate_table}" if intermediate_table.exists?

      queries = [
        "ALTER TABLE #{quote_table(table)} RENAME TO #{quote_no_schema(intermediate_table)};",
        "ALTER TABLE #{quote_table(retired_table)} RENAME TO #{quote_no_schema(table)};"
      ]

      table.sequences.each do |sequence|
        queries << "ALTER SEQUENCE #{quote_ident(sequence["sequence_name"])} OWNED BY #{quote_table(table)}.#{quote_ident(sequence["related_column"])};"
      end

      run_queries(queries)
    end

    def analyze
      table = Table.new(qualify_table(arguments.first))
      parent_table = options[:swapped] ? table : table.intermediate_table

      abort "Usage: pgslice analyze <table>" if arguments.length != 1

      existing_tables = table.existing_partitions
      analyze_list = existing_tables + [parent_table]
      run_queries_without_transaction(analyze_list.map { |t| "ANALYZE VERBOSE #{quote_table(t)};" })
    end

    # arguments

    def parse_args(args)
      opts = Slop.parse(args) do |o|
        o.boolean "--intermediate"
        o.boolean "--swapped"
        o.float "--sleep"
        o.integer "--future", default: 0
        o.integer "--past", default: 0
        o.integer "--batch-size", default: 10000
        o.boolean "--dry-run", default: false
        o.boolean "--no-partition", default: false
        o.boolean "--trigger-based", default: false
        o.integer "--start"
        o.string "--url"
        o.string "--source-table"
        o.string "--dest-table"
        o.string "--where"
        o.string "--lock-timeout", default: "5s"
        o.on "-v", "--version", "print the version" do
          log PgSlice::VERSION
          @exit = true
        end
      end
      @arguments = opts.arguments
      @options = opts.to_hash
    rescue Slop::Error => e
      abort e.message
    end

    # output

    def log(message = nil)
      $stderr.puts message
    end

    def log_sql(message = nil)
      $stdout.puts message
    end

    def abort(message)
      raise PgSlice::Error, message
    end

    # database connection

    def connection
      @connection ||= begin
        url = options[:url] || ENV["PGSLICE_URL"]
        abort "Set PGSLICE_URL or use the --url option" unless url

        uri = URI.parse(url)
        params = CGI.parse(uri.query.to_s)
        # remove schema
        @schema = Array(params.delete("schema") || "public")[0]
        uri.query = URI.encode_www_form(params)

        ENV["PGCONNECT_TIMEOUT"] ||= "1"
        PG::Connection.new(uri.to_s)
      end
    rescue PG::ConnectionBad => e
      abort e.message
    rescue URI::InvalidURIError
      abort "Invalid url"
    end

    def schema
      connection # ensure called first
      @schema
    end

    def execute(query, params = [])
      connection.exec_params(query, params).to_a
    end

    def run_queries(queries)
      connection.transaction do
        execute("SET LOCAL client_min_messages TO warning") unless options[:dry_run]
        log_sql "BEGIN;"
        log_sql
        run_queries_without_transaction(queries)
        log_sql "COMMIT;"
      end
    end

    def run_query(query)
      log_sql query
      unless options[:dry_run]
        begin
          execute(query)
        rescue PG::ServerError => e
          abort("#{e.class.name}: #{e.message}")
        end
      end
      log_sql
    end

    def run_queries_without_transaction(queries)
      queries.each do |query|
        run_query(query)
      end
    end

    def server_version_num
      execute("SHOW server_version_num")[0]["server_version_num"].to_i
    end

    def existing_partitions(table, period = nil)
      Table.new(table).existing_partitions(period)
    end

    def table_exists?(table)
      Table.new(table).exists?
    end

    def columns(table)
      Table.new(table).columns
    end

    # http://stackoverflow.com/a/20537829
    def primary_key(table)
      Table.new(table).primary_key
    end

    def has_trigger?(trigger_name, table)
      !fetch_trigger(trigger_name, table).nil?
    end

    def fetch_comment(table)
      execute("SELECT obj_description(#{regclass(table)}) AS comment")[0]
    end

    # helpers

    def trigger_name(table)
      Table.new(table).trigger_name
    end

    def column_cast(table, column)
      Table.new(table).column_cast(column)
    end

    def sql_date(time, cast, add_cast = true)
      if cast == "timestamptz"
        fmt = "%Y-%m-%d %H:%M:%S UTC"
      else
        fmt = "%Y-%m-%d"
      end
      str = "'#{time.strftime(fmt)}'"
      add_cast ? "#{str}::#{cast}" : str
    end

    def name_format(period)
      case period.to_sym
      when :day
        "%Y%m%d"
      else
        "%Y%m"
      end
    end

    def round_date(date, period)
      date = date.to_date
      case period.to_sym
      when :day
        date
      else
        Date.new(date.year, date.month)
      end
    end

    def advance_date(date, period, count = 1)
      date = date.to_date
      case period.to_sym
      when :day
        date.next_day(count)
      else
        date.next_month(count)
      end
    end

    def quote_ident(value)
      PG::Connection.quote_ident(value)
    end

    def quote_table(table)
      table.to_s.split(".", 2).map { |v| quote_ident(v) }.join(".")
    end

    def quote_no_schema(table)
      quote_ident(table.to_s.split(".", 2)[-1])
    end

    def regclass(table)
      "'#{quote_table(table)}'::regclass"
    end

    def fetch_trigger(trigger_name, table)
      execute("SELECT obj_description(oid, 'pg_trigger') AS comment FROM pg_trigger WHERE tgname = $1 AND tgrelid = #{regclass(table)}", [trigger_name])[0]
    end

    def qualify_table(table)
      table.to_s.include?(".") ? table : [schema, table].join(".")
    end

    def settings_from_trigger(original_table, table)
      trigger_name = self.trigger_name(original_table)

      needs_comment = false
      trigger_comment = fetch_trigger(trigger_name, table)
      comment = trigger_comment || fetch_comment(table)
      if comment
        field, period, cast = comment["comment"].split(",").map { |v| v.split(":").last } rescue [nil, nil, nil]
      end

      unless period
        needs_comment = true
        function_def = execute("select pg_get_functiondef(oid) from pg_proc where proname = $1", [trigger_name])[0]
        return [] unless function_def
        function_def = function_def["pg_get_functiondef"]
        sql_format = SQL_FORMAT.find { |_, f| function_def.include?("'#{f}'") }
        return [] unless sql_format
        period = sql_format[0]
        field = /to_char\(NEW\.(\w+),/.match(function_def)[1]
      end

      # backwards compatibility with 0.2.3 and earlier (pre-timestamptz support)
      unless cast
        cast = "date"
        # update comment to explicitly define cast
        needs_comment = true
      end

      [period, field, cast, needs_comment, !trigger_comment]
    end

    def foreign_keys(table)
      execute("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = #{regclass(table)} AND contype ='f'").map { |r| r["pg_get_constraintdef"] }
    end
  end
end
