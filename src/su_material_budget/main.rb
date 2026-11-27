# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'csv'
require 'net/http'
require 'uri'
require 'thread'
require 'zlib'
require 'rexml/document'

module StudioTools
  module MaterialBudget
    extend self

    PLUGIN_ID = 'studio_tools.material_budget'
    DICT_NAME = 'StudioTools_MaterialBudget'
    PRICE_KEY = 'material_prices_json'
    SELECTED_KEY = 'selected_material_names_json'
    LIBRARY_KEY = 'price_library_json'
    BASELINE_KEY = 'budget_baseline_json'
    PROJECT_BUDGET_KEY = 'project_budget_amount'
    LINKED_FILE_KEY = 'linked_price_file'
    LINKED_SYNC_KEY = 'linked_price_sync_json'
    MAPPING_HISTORY_KEY = 'material_mapping_history_json'
    MODEL_MAPPING_KEY = 'confirmed_material_mappings_json'
    PREF_SECTION = 'StudioTools.MaterialBudget'
    PREF_LINK_KEY = 'linked_price_file'
    PREF_MAPPING_KEY = 'studio_material_mappings_json'
    PREF_AI_MODEL_KEY = 'deepseek_model'
    PREF_AI_ENDPOINT_KEY = 'deepseek_endpoint'
    DEEPSEEK_ENDPOINT = 'https://api.deepseek.com/chat/completions'
    DEFAULT_DEEPSEEK_MODEL = 'deepseek-chat'
    DEFAULT_LINKED_PRICE_FILE = ''
    M2_PER_SQUARE_INCH = 0.00064516
    REFRESH_DELAY_SECONDS = 0.15
    CONTACT_TOLERANCE_INCHES = 0.1.mm.to_f
    ENTITY_BATCH_SIZE = 350
    OVERLAP_BATCH_SIZE = 1_200
    AGGREGATE_BATCH_SIZE = 700
    TIMER_INTERVAL_SECONDS = 0.01
    PROGRESS_THROTTLE_SECONDS = 0.12

    class BudgetModelObserver < Sketchup::ModelObserver
      def onTransactionCommit(_model)
        StudioTools::MaterialBudget.mark_geometry_dirty_and_schedule
      end

      def onTransactionUndo(_model)
        StudioTools::MaterialBudget.mark_geometry_dirty_and_schedule
      end

      def onTransactionRedo(_model)
        StudioTools::MaterialBudget.mark_geometry_dirty_and_schedule
      end
    end

    class BudgetMaterialsObserver < Sketchup::MaterialsObserver
      def onMaterialSetCurrent(_materials, material)
        StudioTools::MaterialBudget.capture_material(material)
      end

      def onMaterialRemove(_materials, _material)
        StudioTools::MaterialBudget.mark_geometry_dirty_and_schedule
      end
    end

    class BudgetAppObserver < Sketchup::AppObserver
      def expectsStartupModelNotifications
        true
      end

      def onNewModel(model)
        StudioTools::MaterialBudget.attach_model_observer(model)
      end

      def onOpenModel(model)
        StudioTools::MaterialBudget.attach_model_observer(model)
      end

      def onActivateModel(model)
        StudioTools::MaterialBudget.attach_model_observer(model)
        StudioTools::MaterialBudget.mark_geometry_dirty_and_schedule
      end
    end

    def show_dialog
      create_dialog unless @dialog
      @dialog.show
      @capture_enabled = true
      attach_model_observer(Sketchup.active_model)
      start_material_capture_polling
    end

    def create_dialog
      options = {
        dialog_title: '材质实时预算 v0.9.0',
        preferences_key: PLUGIN_ID,
        scrollable: true,
        resizable: true,
        width: 1040,
        height: 720,
        min_width: 760,
        min_height: 440,
        style: UI::HtmlDialog::STYLE_DIALOG
      }
      @dialog = UI::HtmlDialog.new(options)
      @dialog.set_file(File.join(__dir__, 'dialog_v07.html'))
      @dialog.set_on_closed do
        @capture_enabled = false
        stop_material_capture_polling
        cancel_area_calculation
        @dialog = nil
      end

      @dialog.add_action_callback('ready') { |_context| start_area_calculation('打开模型') }
      @dialog.add_action_callback('refresh') { |_context| start_area_calculation('手动重新计算') }
      @dialog.add_action_callback('save_price') do |_context, material_name, raw_price|
        save_material_price(material_name.to_s, raw_price)
      end
      @dialog.add_action_callback('clear_material_price') do |_context, material_name|
        clear_material_price(material_name.to_s)
      end
      @dialog.add_action_callback('highlight_material') do |_context, material_name|
        highlight_material_in_model(material_name.to_s)
      end
      @dialog.add_action_callback('remove_material_mapping') do |_context, material_name|
        remove_material_mapping(material_name.to_s)
      end
      @dialog.add_action_callback('remove_material') do |_context, material_name|
        remove_selected_material(material_name.to_s)
      end
      @dialog.add_action_callback('clear_materials') { |_context| clear_selected_materials }
      @dialog.add_action_callback('link_price_library') { |_context| link_price_library }
      @dialog.add_action_callback('update_linked_price_library') { |_context| update_linked_price_library }
      @dialog.add_action_callback('reset_price_library') { |_context| reset_price_library }
      @dialog.add_action_callback('set_baseline') { |_context| set_budget_baseline }
      @dialog.add_action_callback('save_project_budget') do |_context, raw_amount|
        save_project_budget(raw_amount)
      end
      @dialog.add_action_callback('confirm_material_mapping') do |_context, material_name, standard_code, suggested_code, confidence, reason|
        confirm_material_mapping(material_name.to_s, standard_code.to_s, suggested_code.to_s, confidence, reason.to_s)
      end
      @dialog.add_action_callback('configure_deepseek') do |_context, api_key, model, endpoint = ''|
        configure_deepseek(api_key.to_s, model.to_s, endpoint.to_s)
      end
      @dialog.add_action_callback('request_ai_recommendation') do |_context, material_name|
        request_ai_recommendation(material_name.to_s)
      end
      @dialog.add_action_callback('export_csv') { |_context| export_full_csv }
    end

    def selected_material_names(model)
      saved = model.get_attribute(DICT_NAME, SELECTED_KEY, nil)
      return [] unless saved.is_a?(String) && !saved.empty?

      parsed = JSON.parse(saved)
      parsed.is_a?(Array) ? parsed.map(&:to_s).uniq : []
    rescue JSON::ParserError
      []
    end

    def save_selected_material_names(model, names)
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, SELECTED_KEY, JSON.generate(names.uniq.sort))
      end
    end

    def capture_material(material)
      return unless @capture_enabled && material && material.valid?

      name = material.display_name.to_s
      return if name.empty?

      model = Sketchup.active_model
      names = selected_material_names(model)
      return if names.include?(name)

      names << name
      save_selected_material_names(model, names)
      invalidate_geometry_cache
      start_area_calculation("新增材质：#{name}")
    end

    def material_capture_key(material)
      return nil unless material && material.valid?

      if material.respond_to?(:persistent_id)
        "pid:#{material.persistent_id}"
      else
        "name:#{material.display_name}"
      end
    rescue StandardError
      "name:#{material.display_name}"
    end

    def start_material_capture_polling
      stop_material_capture_polling
      current = Sketchup.active_model.materials.current
      @last_current_material_key = material_capture_key(current)
      @material_capture_timer = UI.start_timer(0.25, true) do
        next unless @capture_enabled && @dialog && @dialog.visible?

        material = Sketchup.active_model.materials.current
        key = material_capture_key(material)
        next if key.nil? || key == @last_current_material_key

        @last_current_material_key = key
        capture_material(material)
      end
    end

    def stop_material_capture_polling
      return unless @material_capture_timer

      UI.stop_timer(@material_capture_timer)
      @material_capture_timer = nil
    rescue StandardError
      @material_capture_timer = nil
    end

    def remove_selected_material(material_name)
      model = Sketchup.active_model
      names = selected_material_names(model)
      names.delete(material_name)
      save_selected_material_names(model, names)
      invalidate_geometry_cache
      start_area_calculation("移除材质：#{material_name}")
    end

    def clear_selected_materials
      save_selected_material_names(Sketchup.active_model, [])
      invalidate_geometry_cache
      start_area_calculation('清空材质')
    end

    def save_material_price(material_name, raw_price)
      price = begin
        Float(raw_price)
      rescue ArgumentError, TypeError
        nil
      end

      unless price && price >= 0
        notify_error('单价必须是大于或等于 0 的数字。')
        return
      end

      model = Sketchup.active_model
      prices = model_prices(model)
      prices[material_name] = price.round(2)
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, PRICE_KEY, JSON.generate(prices))
      end
      refresh_budget
    end

    def clear_material_price(material_name)
      model = Sketchup.active_model
      prices = model_prices(model)
      return unless prices.key?(material_name)

      prices.delete(material_name)
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, PRICE_KEY, JSON.generate(prices))
      end
      notify_info("已恢复「#{material_name}」的价格库单价。")
      refresh_budget
    rescue StandardError => error
      notify_error("恢复价格库单价失败：#{error.message}")
    end

    def remove_material_mapping(material_name)
      model = Sketchup.active_model
      normalized_name = normalized_material_name(material_name)
      model_saved = model.get_attribute(DICT_NAME, MODEL_MAPPING_KEY, '').to_s
      model_mappings = parse_mapping_json(model_saved)
      model_mappings.delete(normalized_name)
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, MODEL_MAPPING_KEY, JSON.generate(model_mappings))
      end
      begin
        global_saved = Sketchup.read_default(PREF_SECTION, PREF_MAPPING_KEY, '').to_s
        global_mappings = parse_mapping_json(global_saved)
        if global_mappings.key?(normalized_name)
          global_mappings.delete(normalized_name)
          Sketchup.write_default(PREF_SECTION, PREF_MAPPING_KEY, JSON.generate(global_mappings))
        end
      rescue StandardError => preference_error
        puts("#{PLUGIN_ID}: 工作室全局词库移除同步失败：#{preference_error.message}")
      end
      notify_info("已解除「#{material_name}」的工作室映射，可重新选择或使用 AI 推荐。")
      refresh_budget
    rescue StandardError => error
      notify_error("解除映射失败：#{error.message}")
    end

    def highlight_material_in_model(material_name)
      model = Sketchup.active_model
      return unless model

      active_entities = model.active_entities
      matched = []
      active_entities.each do |entity|
        next unless entity.valid? && entity.visible?
        next if entity.respond_to?(:layer) && entity.layer && !entity.layer.visible?

        if entity.is_a?(Sketchup::Face)
          mat = billable_surface_material(entity.material, entity.back_material)
          matched << entity if mat && mat.display_name.to_s == material_name
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          matched << entity if container_uses_material?(entity, nil, material_name)
        end
      end

      model.selection.clear
      if matched.empty?
        notify_info("当前编辑层级未找到使用「#{material_name}」的可见面片或组件。")
      else
        model.selection.add(matched)
        model.active_view.refresh
        notify_info("已在模型中高亮选中「#{material_name}」关联的 #{matched.length} 个对象。")
      end
    rescue StandardError => error
      notify_error("模型高亮定位失败：#{error.message}")
    end

    def container_uses_material?(container, inherited_material, target_name)
      child_material = container.material || inherited_material
      entities = container.is_a?(Sketchup::Group) ? container.entities : container.definition.entities
      entities.each do |entity|
        next unless entity.valid? && entity.visible?
        next if entity.respond_to?(:layer) && entity.layer && !entity.layer.visible?

        case entity
        when Sketchup::Face
          mat = billable_surface_material(entity.material || child_material, entity.back_material)
          return true if mat && mat.display_name.to_s == target_name
        when Sketchup::Group, Sketchup::ComponentInstance
          return true if container_uses_material?(entity, child_material, target_name)
        end
      end
      false
    end

    def material_color_hex(model, material_name)
      return '#cbd5e1' unless model && model.materials

      mat = model.materials.find { |item| item.valid? && item.display_name.to_s == material_name }
      return '#cbd5e1' unless mat && mat.color

      color = mat.color
      format('#%02x%02x%02x', color.red, color.green, color.blue)
    rescue StandardError
      '#cbd5e1'
    end

    def model_prices(model)
      saved = model.get_attribute(DICT_NAME, PRICE_KEY, nil)
      return {} unless saved.is_a?(String) && !saved.empty?

      parsed = JSON.parse(saved)
      parsed.transform_values { |value| value.to_f }
    rescue JSON::ParserError
      {}
    end

    def default_price_library
      @default_price_library ||= begin
        path = File.join(__dir__, 'materials.json')
        data = JSON.parse(File.read(path, encoding: 'UTF-8'))
        data = data['price_library'] if data.is_a?(Hash)
        normalize_library(data)
      rescue StandardError
        []
      end
    end

    def model_price_library(model)
      saved = model.get_attribute(DICT_NAME, LIBRARY_KEY, nil)
      return default_price_library unless saved.is_a?(String) && !saved.empty?

      parsed = JSON.parse(saved)
      normalized = normalize_library(parsed)
      normalized.empty? ? default_price_library : normalized
    rescue JSON::ParserError
      default_price_library
    end

    def normalize_library(items)
      return [] unless items.is_a?(Array)

      items.each_with_index.each_with_object([]) do |(raw, index), normalized_items|
        next unless raw.is_a?(Hash)

        name = (raw['standard_name'] || raw[:standard_name] || raw['name'] || raw[:name]).to_s.strip
        next if name.empty?

        components = {
          material_unit_price: numeric_or_zero(raw['material_unit_price'] || raw[:material_unit_price]),
          labor_unit_price: numeric_or_zero(raw['labor_unit_price'] || raw[:labor_unit_price]),
          machinery_unit_price: numeric_or_zero(raw['machinery_unit_price'] || raw[:machinery_unit_price]),
          management_unit_price: numeric_or_zero(raw['management_unit_price'] || raw[:management_unit_price]),
          profit_unit_price: numeric_or_zero(raw['profit_unit_price'] || raw[:profit_unit_price])
        }
        comprehensive = raw['comprehensive_unit_price'] || raw[:comprehensive_unit_price]
        comprehensive = components.values.inject(0.0, :+) if comprehensive.nil? || comprehensive.to_s.strip.empty?
        aliases = raw['aliases'] || raw[:aliases] || []
        aliases = aliases.split(/[|｜,，;；]/) if aliases.is_a?(String)

        normalized_items << {
          standard_code: (raw['standard_code'] || raw[:standard_code] || format('MAT-%03d', index + 1)).to_s,
          category: (raw['category'] || raw[:category] || '未分类').to_s,
          standard_name: name,
          aliases: Array(aliases).map { |value| value.to_s.strip }.reject(&:empty?).uniq,
          unit: (raw['unit'] || raw[:unit] || '㎡').to_s,
          material_unit_price: components[:material_unit_price].round(2),
          labor_unit_price: components[:labor_unit_price].round(2),
          machinery_unit_price: components[:machinery_unit_price].round(2),
          management_unit_price: components[:management_unit_price].round(2),
          profit_unit_price: components[:profit_unit_price].round(2),
          comprehensive_unit_price: numeric_or_zero(comprehensive).round(2),
          source_project_code: (raw['source_project_code'] || raw[:source_project_code]).to_s,
          source_region: (raw['source_region'] || raw[:source_region]).to_s,
          price_date: (raw['price_date'] || raw[:price_date]).to_s,
          source_page: (raw['source_page'] || raw[:source_page]).to_s,
          source_url: (raw['source_url'] || raw[:source_url]).to_s,
          note: (raw['note'] || raw[:note]).to_s
        }
      end
    end

    def normalized_material_name(value)
      value.to_s.downcase.gsub(/[\s_\-—–·・()（）\[\]【】]/, '')
    end

    def library_match(material_name, library)
      target = normalized_material_name(material_name)
      return nil if target.empty?

      library.find do |entry|
        candidates = [entry[:standard_code], entry[:standard_name]] + entry[:aliases]
        candidates.any? { |candidate| normalized_material_name(candidate) == target }
      end
    end

    def price_library_index(library)
      library.each_with_object({}) do |entry, index|
        ([entry[:standard_code], entry[:standard_name]] + entry[:aliases]).each do |candidate|
          key = normalized_material_name(candidate)
          index[key] ||= entry unless key.empty?
        end
      end
    end

    def parse_mapping_json(saved)
      parsed = saved.to_s.empty? ? {} : JSON.parse(saved.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def studio_material_mappings(model = Sketchup.active_model)
      saved = Sketchup.read_default(PREF_SECTION, PREF_MAPPING_KEY, '').to_s
      global_mappings = parse_mapping_json(saved)
      model_saved = model ? model.get_attribute(DICT_NAME, MODEL_MAPPING_KEY, '').to_s : ''
      # Model mappings win so an explicit confirmation affects the open budget
      # immediately even when SketchUp cannot persist a large preference value.
      global_mappings.merge(parse_mapping_json(model_saved))
    end

    def mapping_history(model)
      saved = model.get_attribute(DICT_NAME, MAPPING_HISTORY_KEY, '').to_s
      parsed = saved.empty? ? [] : JSON.parse(saved)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def confirmed_mapping_entry(material_name, library)
      mapping = studio_material_mappings[normalized_material_name(material_name)]
      return nil unless mapping.is_a?(Hash)

      code = mapping['standard_code'].to_s
      library.find { |entry| entry[:standard_code].to_s == code }
    end

    def material_name_bigrams(value)
      chars = normalized_material_name(value).each_char.to_a
      return chars if chars.length < 2

      chars.each_cons(2).map(&:join).uniq
    end

    def material_keyword_hits(material_name, entry)
      source = material_name.to_s.downcase
      target = "#{entry[:standard_name]} #{entry[:category]} #{entry[:aliases].join(' ')}".downcase
      %w[墙 地 顶 天花 木 石 玻璃 金属 砖 瓷砖 涂料 乳胶漆 抹灰 水泥 混凝土 防水 保温].select do |keyword|
        source.include?(keyword) && target.include?(keyword)
      end
    end

    def ai_material_suggestions(material_name, library, limit = 3)
      source = normalized_material_name(material_name)
      source_pairs = material_name_bigrams(source)
      library.map do |entry|
        candidates = [entry[:standard_name], entry[:standard_code]] + entry[:aliases]
        best_similarity = candidates.map do |candidate|
          target = normalized_material_name(candidate)
          target_pairs = material_name_bigrams(target)
          overlap = (source_pairs & target_pairs).length
          dice = source_pairs.empty? || target_pairs.empty? ? 0.0 : (2.0 * overlap / (source_pairs.length + target_pairs.length))
          containment = (!source.empty? && !target.empty? && (source.include?(target) || target.include?(source))) ? 0.22 : 0.0
          [dice + containment, 1.0].min
        end.max.to_f
        keywords = material_keyword_hits(material_name, entry)
        score = [[(best_similarity * 72.0) + (keywords.length * 9.0) + 8.0, 20.0].max, 96.0].min.round
        reason_parts = ["名称相似度 #{(best_similarity * 100).round}%"]
        reason_parts << "共同特征：#{keywords.join('、')}" unless keywords.empty?
        reason_parts << "归入#{entry[:category]}候选"
        {
          standard_code: entry[:standard_code], standard_name: entry[:standard_name], category: entry[:category],
          confidence: score, reason: reason_parts.join('；')
        }
      end.sort_by { |item| [-item[:confidence], item[:standard_code]] }.first(limit)
    end

    def confirm_material_mapping(material_name, standard_code, suggested_code, confidence, reason)
      model = Sketchup.active_model
      selected = model_price_library(model).find { |entry| entry[:standard_code].to_s == standard_code }
      unless selected
        notify_error('选择的标准材料已经不在当前价格库中，请更新价格表后重试。')
        return
      end

      mapping = {
        'source_material' => material_name, 'standard_code' => selected[:standard_code],
        'standard_name' => selected[:standard_name], 'confirmed_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
      normalized_name = normalized_material_name(material_name)
      mappings = studio_material_mappings(model)
      mappings[normalized_name] = mapping
      history = mapping_history(model)
      history << {
        'source_material' => material_name, 'ai_suggestion' => suggested_code,
        'ai_confidence' => numeric_or_zero(confidence).round, 'ai_reason' => reason,
        'human_choice' => standard_code, 'final_result' => "#{selected[:standard_code]} #{selected[:standard_name]}",
        'confirmed_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, MODEL_MAPPING_KEY, JSON.generate(mappings))
        model.set_attribute(DICT_NAME, MAPPING_HISTORY_KEY, JSON.generate(history.last(500)))
      end
      begin
        Sketchup.write_default(PREF_SECTION, PREF_MAPPING_KEY, JSON.generate(mappings))
      rescue StandardError => preference_error
        puts("#{PLUGIN_ID}: 工作室全局词库同步失败，当前模型映射仍已保存：#{preference_error.message}")
      end
      notify_info("已确认映射：#{material_name} → #{selected[:standard_code]} #{selected[:standard_name]}，并保存到工作室词库。")
      refresh_budget
    rescue StandardError => error
      notify_error("保存材质映射失败：#{error.message}")
    end

    def deepseek_model
      saved = Sketchup.read_default(PREF_SECTION, PREF_AI_MODEL_KEY, DEFAULT_DEEPSEEK_MODEL).to_s.strip
      saved.empty? ? DEFAULT_DEEPSEEK_MODEL : saved
    end

    def deepseek_endpoint
      saved = Sketchup.read_default(PREF_SECTION, PREF_AI_ENDPOINT_KEY, DEEPSEEK_ENDPOINT).to_s.strip
      saved.empty? ? DEEPSEEK_ENDPOINT : saved
    end

    def configure_deepseek(api_key, model, endpoint = '')
      key = api_key.to_s.strip
      if key.length < 8
        notify_error('API Key 格式不正确（至少 8 位）。密钥只保存在本次 SketchUp 运行内存中。')
        return
      end

      selected_endpoint = endpoint.to_s.strip
      selected_endpoint = DEEPSEEK_ENDPOINT if selected_endpoint.empty?
      unless selected_endpoint.start_with?('https://', 'http://')
        notify_error('API 地址必须以 https:// 或 http:// 开头。')
        return
      end

      @deepseek_api_key = key
      selected_model = model.to_s.strip.empty? ? DEFAULT_DEEPSEEK_MODEL : model.to_s.strip
      Sketchup.write_default(PREF_SECTION, PREF_AI_MODEL_KEY, selected_model)
      Sketchup.write_default(PREF_SECTION, PREF_AI_ENDPOINT_KEY, selected_endpoint)
      @dialog.execute_script("window.MaterialBudget.aiConfigured(#{JSON.generate(selected_model)});") if @dialog && @dialog.visible?
      notify_info("AI 推荐已启用（#{selected_model}）；API Key 未写入模型或工作室词库。")
    end

    def request_ai_recommendation(material_name)
      unless @deepseek_api_key && !@deepseek_api_key.empty?
        deliver_local_recommendation(material_name, '尚未配置 DeepSeek，已使用本地推荐。')
        return
      end

      library = model_price_library(Sketchup.active_model)
      @dialog.execute_script("window.MaterialBudget.aiLoading(#{JSON.generate(material_name)});") if @dialog && @dialog.visible?
      api_key = @deepseek_api_key.dup
      model_name = deepseek_model
      endpoint_url = deepseek_endpoint
      @ai_result_queue ||= Queue.new
      @ai_pending_requests = @ai_pending_requests.to_i + 1
      start_ai_result_polling
      Thread.new do
        begin
          suggestions = deepseek_recommendations(material_name, library, api_key, model_name, endpoint_url)
          @ai_result_queue << { material_name: material_name, suggestions: suggestions, provider: "AI · #{model_name}" }
        rescue StandardError => error
          @ai_result_queue << { material_name: material_name, error: error.message }
        end
      end
    end

    def start_ai_result_polling
      return if @ai_result_timer

      @ai_result_timer = UI.start_timer(0.1, true) do
        begin
          loop do
            result = @ai_result_queue.pop(true)
            @ai_pending_requests -= 1
            if result[:error]
              deliver_local_recommendation(result[:material_name], "AI 调用失败：#{result[:error]}；已切换本地推荐。")
            else
              deliver_ai_recommendation(result[:material_name], result[:suggestions], result[:provider])
            end
          end
        rescue ThreadError
          if @ai_pending_requests.to_i <= 0
            UI.stop_timer(@ai_result_timer)
            @ai_result_timer = nil
          end
        end
      end
    end

    def deepseek_recommendations(material_name, library, api_key, model_name, endpoint_url = DEEPSEEK_ENDPOINT)
      options = library.map do |entry|
        { code: entry[:standard_code], name: entry[:standard_name], category: entry[:category], aliases: entry[:aliases].first(8) }
      end
      prompt = {
        task: '把SketchUp非标准材质匹配到给定标准材料，只能选择清单中的code。输出JSON。',
        source_material: material_name,
        candidates: options,
        output_example: { suggestions: [{ code: 'WALL-002', confidence: 86, reason: '名称与墙面抹灰用途接近' }] }
      }
      uri = URI(endpoint_url)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{api_key}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate({
        model: model_name,
        messages: [
          { role: 'system', content: '你是建筑材料造价映射助手。返回严格JSON，给出最多3个候选、0到100置信度和简短可核验理由。不要选择候选清单以外的编码。' },
          { role: 'user', content: JSON.generate(prompt) }
        ],
        response_format: { type: 'json_object' },
        temperature: 0.2,
        max_tokens: 700
      })
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 8
      http.read_timeout = 35
      response = http.request(request)
      raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      envelope = JSON.parse(response.body)
      content = envelope.dig('choices', 0, 'message', 'content').to_s.strip
      content = content.sub(/\A```(?:json)?\s*/i, '').sub(/\s*```\z/, '')
      parsed = JSON.parse(content)
      allowed = library.each_with_object({}) { |entry, index| index[entry[:standard_code].to_s] = entry }
      suggestions = Array(parsed['suggestions']).first(3).each_with_object([]) do |item, valid_items|
        entry = allowed[item['code'].to_s]
        next unless entry

        valid_items << {
          standard_code: entry[:standard_code], standard_name: entry[:standard_name], category: entry[:category],
          confidence: [[numeric_or_zero(item['confidence']).round, 0].max, 100].min,
          reason: item['reason'].to_s.strip.empty? ? 'AI根据名称和标准材料清单推荐' : item['reason'].to_s.strip
        }
      end
      raise '模型未返回有效候选' if suggestions.empty?

      suggestions
    end

    def deliver_ai_recommendation(material_name, suggestions, provider)
      return unless @dialog && @dialog.visible?

      payload = { material_name: material_name, suggestions: suggestions, provider: provider }
      @dialog.execute_script("window.MaterialBudget.aiRecommendation(#{JSON.generate(payload)});")
    end

    def deliver_local_recommendation(material_name, notice)
      suggestions = ai_material_suggestions(material_name, model_price_library(Sketchup.active_model))
      deliver_ai_recommendation(material_name, suggestions, '本地可解释推荐')
      notify_info(notice)
    end

    def budget_baseline(model)
      saved = model.get_attribute(DICT_NAME, BASELINE_KEY, nil)
      return nil unless saved.is_a?(String) && !saved.empty?

      parsed = JSON.parse(saved)
      amount = parsed['amount']
      return nil unless amount.is_a?(Numeric)

      { amount: amount.to_f, captured_at: parsed['captured_at'].to_s }
    rescue JSON::ParserError
      nil
    end

    def project_budget(model)
      value = model.get_attribute(DICT_NAME, PROJECT_BUDGET_KEY, nil)
      return nil if value.nil? || value.to_s.strip.empty?

      amount = numeric_or_zero(value)
      amount.positive? ? amount : nil
    end

    def save_project_budget(raw_amount)
      amount = numeric_or_zero(raw_amount)
      if amount <= 0
        notify_error('项目总预算必须是大于0的数字。')
        return
      end

      without_geometry_invalidation do
        Sketchup.active_model.set_attribute(DICT_NAME, PROJECT_BUDGET_KEY, amount)
      end
      notify_info("项目总预算已保存：¥#{format('%.2f', amount)}。")
      refresh_budget
    rescue StandardError => error
      notify_error("保存项目总预算失败：#{error.message}")
    end

    def set_budget_baseline
      model = Sketchup.active_model
      unless geometry_cache_valid?(model)
        start_area_calculation('设置基准前重新计算')
        notify_info('面积正在重新计算，完成后请再次点击“设为基准”。')
        return
      end
      result = calculate_budget(model, @geometry_cache)
      baseline = { amount: result[:total_budget], captured_at: Time.now.strftime('%Y-%m-%d %H:%M:%S') }
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, BASELINE_KEY, JSON.generate(baseline))
      end
      notify_info("已将 ¥#{format('%.2f', baseline[:amount])} 设为预算基准。")
      refresh_budget
    rescue StandardError => error
      notify_error("设置预算基准失败：#{error.message}")
    end

    def linked_price_file(model = Sketchup.active_model)
      model_path = model.get_attribute(DICT_NAME, LINKED_FILE_KEY, '').to_s.strip
      return model_path unless model_path.empty?

      global_path = Sketchup.read_default(PREF_SECTION, PREF_LINK_KEY, '').to_s.strip
      return global_path unless global_path.empty?

      File.file?(DEFAULT_LINKED_PRICE_FILE) ? DEFAULT_LINKED_PRICE_FILE : ''
    end

    def save_linked_price_file(model, path)
      normalized = File.expand_path(path).tr('\\', '/')
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, LINKED_FILE_KEY, normalized)
      end
      Sketchup.write_default(PREF_SECTION, PREF_LINK_KEY, normalized)
      normalized
    end

    def linked_sync_info(model)
      saved = model.get_attribute(DICT_NAME, LINKED_SYNC_KEY, nil)
      return {} unless saved.is_a?(String) && !saved.empty?

      parsed = JSON.parse(saved)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def link_price_library
      current = linked_price_file
      directory = current.empty? ? nil : File.dirname(current)
      path = UI.openpanel('关联材质与人工价格表（只需选择一次）', directory, '价格库|*.xlsx;*.xls;*.csv||')
      return unless path

      saved_path = save_linked_price_file(Sketchup.active_model, path)
      sync_price_library_from_path(saved_path, '关联并更新')
    rescue StandardError => error
      notify_error("关联价格表失败：#{error.message}")
    end

    def update_linked_price_library
      path = linked_price_file
      if path.empty?
        notify_error('尚未关联价格表，请先点击“关联价格表”。')
        return
      end

      unless File.file?(path)
        notify_error("已关联的价格表不存在或已移动：#{path}。请重新关联一次。")
        return
      end

      sync_price_library_from_path(path, '更新')
    rescue StandardError => error
      notify_error("更新价格失败：#{error.message}")
    end

    def sync_price_library_from_path(path, action_name)
      rows = File.extname(path).downcase == '.csv' ? rows_from_csv(path) : rows_from_excel(path)
      library = build_library_from_rows(rows)
      raise '未找到可读取的数据行，请检查“价格库”工作表的表头和价格列。' if library.empty?

      model = Sketchup.active_model
      saved_path = save_linked_price_file(model, path)
      synced_at = Time.now.strftime('%Y-%m-%d %H:%M:%S')
      sync_info = {
        path: saved_path,
        synced_at: synced_at,
        row_count: library.length,
        file_mtime: File.mtime(saved_path).strftime('%Y-%m-%d %H:%M:%S')
      }
      without_geometry_invalidation do
        model.set_attribute(DICT_NAME, LIBRARY_KEY, JSON.generate(library))
        model.set_attribute(DICT_NAME, LINKED_SYNC_KEY, JSON.generate(sync_info))
      end
      notify_info("价格表#{action_name}成功：#{library.length} 条，#{synced_at}。")
      refresh_budget
    end

    def reset_price_library
      model = Sketchup.active_model
      without_geometry_invalidation { model.delete_attribute(DICT_NAME, LIBRARY_KEY) }
      notify_info("已恢复插件自带示例价格库（#{default_price_library.length} 条）。")
      refresh_budget
    rescue StandardError => error
      notify_error("恢复示例价格库失败：#{error.message}")
    end

    def rows_from_csv(path)
      CSV.read(path, encoding: 'bom|utf-8').map(&:to_a)
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      CSV.read(path, encoding: 'GB18030:UTF-8').map(&:to_a)
    end

    def rows_from_excel(path)
      if File.extname(path).downcase == '.xlsx'
        begin
          return rows_from_xlsx_pure_ruby(path)
        rescue StandardError => xlsx_error
          puts("#{PLUGIN_ID}: pure-Ruby XLSX read failed, falling back to WIN32OLE: #{xlsx_error.message}")
        end
      end
      rows_from_excel_win32ole(path)
    end

    def rows_from_xlsx_pure_ruby(path)
      entries = read_zip_entries_pure_ruby(path)
      workbook_xml = entries['xl/workbook.xml']
      rels_xml = entries['xl/_rels/workbook.xml.rels']
      raise '不是有效的 XLSX 文件（缺少 xl/workbook.xml）' unless workbook_xml && rels_xml

      wb_doc = REXML::Document.new(workbook_xml)
      rels_doc = REXML::Document.new(rels_xml)
      rel_map = {}
      rels_doc.elements.each('//Relationship') do |rel|
        rel_map[rel.attributes['Id'].to_s] = rel.attributes['Target'].to_s
      end

      sheets = []
      wb_doc.elements.each('//sheet') do |sheet|
        sheets << {
          name: sheet.attributes['name'].to_s,
          rid: (sheet.attributes['r:id'] || sheet.attributes['id']).to_s
        }
      end
      raise '工作簿中没有工作表' if sheets.empty?

      target_sheet = sheets.find { |s| s[:name] == '价格库' } || sheets.first
      target_rel = rel_map[target_sheet[:rid]].to_s.sub(%r{\A/+}, '')
      sheet_path = target_rel.start_with?('xl/') ? target_rel : "xl/#{target_rel}"
      sheet_xml = entries[sheet_path]
      raise "找不到工作表内容：#{sheet_path}" unless sheet_xml

      shared_strings = []
      if entries['xl/sharedStrings.xml']
        ss_doc = REXML::Document.new(entries['xl/sharedStrings.xml'])
        ss_doc.elements.each('//si') do |si|
          text = si.get_elements('.//t').map { |node| node.text.to_s }.join
          shared_strings << text
        end
      end

      sheet_doc = REXML::Document.new(sheet_xml)
      rows = []
      sheet_doc.elements.each('//sheetData/row') do |row_el|
        row_values = []
        row_el.elements.each('c') do |cell|
          ref = cell.attributes['r'].to_s
          col_index = xlsx_column_index(ref)
          col_index = row_values.length if col_index.nil?
          cell_type = cell.attributes['t'].to_s
          val_node = cell.elements['v']
          value = case cell_type
                  when 's'
                    val_node ? shared_strings[val_node.text.to_i].to_s : ''
                  when 'inlineStr'
                    cell.get_elements('.//t').map { |node| node.text.to_s }.join
                  when 'b'
                    val_node && val_node.text == '1' ? 'TRUE' : 'FALSE'
                  when 'str', 'e'
                    val_node ? val_node.text.to_s : ''
                  else
                    val_node ? val_node.text : nil
                  end
          row_values[col_index] = value
        end
        rows << row_values unless row_values.compact.empty?
      end
      rows
    end

    def xlsx_column_index(cell_ref)
      letters = cell_ref[/\A([A-Za-z]+)/, 1]
      return nil unless letters

      index = 0
      letters.upcase.each_byte do |byte|
        index = (index * 26) + (byte - 64)
      end
      index - 1
    end

    def read_zip_entries_pure_ruby(path)
      data = File.binread(path)
      eocd_pos = data.rindex("PK\x05\x06")
      raise '无效的 ZIP/XLSX 文件结构' unless eocd_pos

      total_entries, _cd_size, cd_offset = data[eocd_pos + 10, 10].unpack('vVV')
      entries = {}
      pos = cd_offset
      total_entries.times do
        break if pos.nil? || pos + 46 > data.bytesize
        break unless data[pos, 4] == "PK\x01\x02"

        method = data[pos + 10, 2].unpack('v')[0]
        comp_size, _uncomp_size = data[pos + 20, 8].unpack('VV')
        name_len, extra_len, comment_len = data[pos + 28, 6].unpack('vvv')
        local_offset = data[pos + 42, 4].unpack('V')[0]
        name = data[pos + 46, name_len].force_encoding('UTF-8')
        pos += 46 + name_len + extra_len + comment_len

        next unless name.start_with?('xl/') && name.end_with?('.xml', '.rels')
        next unless data[local_offset, 4] == "PK\x03\x04"

        local_name_len, local_extra_len = data[local_offset + 26, 4].unpack('vv')
        content_start = local_offset + 30 + local_name_len + local_extra_len
        raw = data[content_start, comp_size]
        content = if method == 0
                    raw
                  elsif method == 8
                    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                    begin
                      inflater.inflate(raw)
                    ensure
                      inflater.close
                    end
                  else
                    raise "不支持的 ZIP 压缩方式：#{method}"
                  end
        entries[name] = content.force_encoding('UTF-8')
      end
      entries
    end

    def rows_from_excel_win32ole(path)
      require 'win32ole'
      excel = WIN32OLE.new('Excel.Application')
      excel.Visible = false
      excel.DisplayAlerts = false
      workbook = excel.Workbooks.Open(File.expand_path(path), nil, true)
      sheet = begin
        workbook.Worksheets('价格库')
      rescue StandardError
        workbook.Worksheets(1)
      end
      values = sheet.UsedRange.Value
      Array(values).map { |row| Array(row) }
    rescue LoadError
      raise '当前环境无法使用 Excel COM 接口，请使用标准 .xlsx 或 .csv 文件导入。'
    rescue StandardError => error
      raise "无法读取Excel（请确认文件未损坏，或另存为 .xlsx/.csv 后导入）：#{error.message}"
    ensure
      workbook.Close(false) if defined?(workbook) && workbook
      excel.Quit if defined?(excel) && excel
    end

    def header_key(value)
      value.to_s.sub(/^\uFEFF/, '').downcase.gsub(/[\s_\-—–()（）\[\]【】\/\\]/, '')
    end

    def header_aliases
      {
        standard_code: %w[标准编码 材料编码 编码 code standardcode],
        category: %w[分类 材料分类 category],
        standard_name: %w[标准材质名称 材质名称 材料名称 名称 standardname name],
        aliases: ['别名', '别名|分隔', '材质别名', 'aliases', 'alias'],
        unit: %w[单位 unit],
        material_unit_price: ['材料单价元㎡', '材料费元㎡', '材料单价', '材料费', 'materialunitprice'],
        labor_unit_price: ['人工单价元㎡', '人工费元㎡', '人工单价', '人工费', 'laborunitprice'],
        machinery_unit_price: ['机械单价元㎡', '机械费元㎡', '机械单价', '机械费', 'machineryunitprice'],
        management_unit_price: ['管理费元㎡', '管理费', 'managementunitprice'],
        profit_unit_price: ['利润元㎡', '利润', 'profitunitprice'],
        comprehensive_unit_price: ['综合单价元㎡', '综合单价', 'unitprice', 'comprehensiveunitprice'],
        source_project_code: %w[来源清单编码 清单编码 sourceprojectcode],
        source_region: %w[地区 来源地区 sourceregion],
        price_date: %w[价格日期 日期 pricedate],
        source_page: %w[来源页码 页码 sourcepage],
        source_url: %w[来源url 来源链接 sourceurl url],
        note: %w[备注 说明 note]
      }
    end

    def build_library_from_rows(rows)
      header_row_index = Array(rows).first(20).index do |row|
        normalized = Array(row).map { |value| header_key(value) }
        normalized.any? { |key| header_aliases[:standard_name].map { |item| header_key(item) }.include?(key) }
      end
      raise '找不到“标准材质名称/材质名称”表头。' unless header_row_index

      headers = Array(rows[header_row_index]).map { |value| header_key(value) }
      column_map = {}
      header_aliases.each do |field, aliases|
        normalized_aliases = aliases.map { |item| header_key(item) }
        column_map[field] = headers.index { |header| normalized_aliases.include?(header) }
      end
      raise '价格库至少需要“材料单价”或“综合单价”列。' unless column_map[:material_unit_price] || column_map[:comprehensive_unit_price]

      imported = rows[(header_row_index + 1)..-1].to_a.each_with_object([]) do |row, items|
        values = Array(row)
        raw = {}
        column_map.each { |field, column| raw[field.to_s] = values[column] if column }
        next if raw['standard_name'].to_s.strip.empty?

        items << raw
      end
      normalize_library(imported)
    end

    def invalidate_geometry_cache
      @geometry_dirty = true
      @geometry_cache = nil
    end

    def without_geometry_invalidation
      previous = @suppress_geometry_dirty
      @suppress_geometry_dirty = true
      yield
    ensure
      @suppress_geometry_dirty = previous
    end

    def geometry_cache_valid?(model)
      return false unless @geometry_cache && !@geometry_dirty

      signature = selected_material_names(model).sort.join("\u0000")
      @geometry_cache[:model_object_id] == model.object_id &&
        @geometry_cache[:selected_signature] == signature
    end

    def mark_geometry_dirty_and_schedule
      return if @suppress_geometry_dirty

      invalidate_geometry_cache
      schedule_refresh
    end

    def cancel_area_calculation
      UI.stop_timer(@calculation_timer) if @calculation_timer
      @calculation_timer = nil
      @calculation_state = nil
    rescue StandardError
      @calculation_timer = nil
      @calculation_state = nil
    end

    def start_area_calculation(reason = '重新计算')
      return unless @dialog && @dialog.visible?

      cancel_area_calculation
      model = Sketchup.active_model
      selected_names = selected_material_names(model)
      selected_lookup = selected_names.each_with_object({}) { |name, lookup| lookup[name] = true }
      initial_queue = []
      model.entities.each { |entity| initial_queue << [entity, Geom::Transformation.new, nil] }
      @geometry_dirty = true
      @calculation_state = {
        token: "#{Time.now.to_f}-#{rand(1_000_000)}",
        model: model,
        selected_names: selected_names,
        selected_lookup: selected_lookup,
        selected_signature: selected_names.sort.join("\u0000"),
        queue: initial_queue,
        queue_index: 0,
        processed_entities: 0,
        discovered_entities: initial_queue.length,
        scan_progress_peak: 0.0,
        current_material: '',
        records: [],
        overlaps: Hash.new(0.0),
        scan_stats: {
          skipped_entities: 0,
          excluded_contact_faces: 0,
          excluded_contact_area_sq_in: 0.0
        },
        stage: :scan,
        reason: reason,
        started_at: Time.now,
        last_progress_at: nil
      }
      notify_calculation_progress(@calculation_state, 0.0, '准备模型实体', force: true)
      token = @calculation_state[:token]
      @calculation_timer = UI.start_timer(TIMER_INTERVAL_SECONDS, true) do
        process_calculation_batch(token)
      end
    rescue StandardError => error
      cancel_area_calculation
      notify_error("面积计算启动失败：#{error.message}")
    end

    def process_calculation_batch(token)
      state = @calculation_state
      return unless state && state[:token] == token

      case state[:stage]
      when :scan
        process_entity_scan_batch(state)
      when :overlap
        process_overlap_batch(state)
      when :aggregate
        process_aggregate_batch(state)
      end
    rescue StandardError => error
      cancel_area_calculation
      notify_error("面积计算失败：#{error.message}")
      puts("#{PLUGIN_ID}: progressive calculation failed: #{error.full_message}")
    end

    def process_entity_scan_batch(state)
      processed_in_batch = 0
      while processed_in_batch < ENTITY_BATCH_SIZE && state[:queue_index] < state[:queue].length
        entity, transform, inherited_material = state[:queue][state[:queue_index]]
        state[:queue_index] += 1
        state[:processed_entities] += 1
        processed_in_batch += 1
        begin
          next unless entity.valid? && entity.visible?
          next if entity.respond_to?(:layer) && entity.layer && !entity.layer.visible?

          case entity
          when Sketchup::Face
            collect_selected_surface_record(entity, transform, inherited_material, state)
          when Sketchup::Group
            child_transform = transform * entity.transformation
            child_material = entity.material || inherited_material
            entity.entities.each { |child| state[:queue] << [child, child_transform, child_material] }
          when Sketchup::ComponentInstance
            child_transform = transform * entity.transformation
            child_material = entity.material || inherited_material
            entity.definition.entities.each { |child| state[:queue] << [child, child_transform, child_material] }
          end
        rescue StandardError => error
          state[:scan_stats][:skipped_entities] += 1
          puts("#{PLUGIN_ID}: fast scan skipped entity: #{error.message}")
        end
      end
      state[:discovered_entities] = state[:queue].length
      ratio = state[:processed_entities].to_f / [state[:discovered_entities], 1].max
      state[:scan_progress_peak] = [state[:scan_progress_peak], ratio].max
      notify_calculation_progress(
        state,
        [state[:scan_progress_peak] * 55.0, 54.5].min,
        "已扫描 #{state[:processed_entities]}/#{state[:discovered_entities]} 个实体，找到 #{state[:records].length} 个计价面"
      )
      prepare_overlap_stage(state) if state[:queue_index] >= state[:queue].length
    end

    def collect_selected_surface_record(face, transform, inherited_material, state)
      material = billable_surface_material(face.material || inherited_material, face.back_material)
      return unless material

      name = material.display_name.to_s
      return unless state[:selected_lookup][name]

      area = face.area(transform)
      return unless area.is_a?(Numeric) && area.finite? && area > 0

      points = face.outer_loop.vertices.map { |vertex| vertex.position.transform(transform) }
      normal = world_normal(face, transform, points)
      state[:current_material] = name
      state[:records] << {
        id: state[:records].length,
        name: name,
        area: area,
        face: face,
        transform: transform,
        triangles: nil,
        projected_axis: nil,
        projected_triangles: nil,
        normal: normal,
        plane_key: plane_key(normal, points),
        bounds: point_bounds(points)
      }
    end

    def prepare_overlap_stage(state)
      groups = state[:records].group_by { |record| record[:plane_key] }.values.map do |records|
        spans = 3.times.map do |axis|
          records.map { |record| record[:bounds][:max][axis] }.max.to_f -
            records.map { |record| record[:bounds][:min][axis] }.min.to_f
        end
        axis = spans.each_with_index.max[1]
        sorted = records.sort_by { |record| record[:bounds][:min][axis] }
        { records: sorted, axis: axis, i: 0, j: 1 }
      end
      state[:overlap_groups] = groups
      state[:overlap_group_index] = 0
      state[:overlap_processed_pairs] = 0
      state[:overlap_total_pairs] = groups.inject(0) do |sum, group|
        count = group[:records].length
        sum + (count * (count - 1) / 2)
      end
      state[:stage] = :overlap
      notify_calculation_progress(state, 55.0, "已提前过滤到 #{state[:records].length} 个计价面，开始检查重叠", force: true)
      prepare_aggregate_stage(state) if state[:overlap_total_pairs].zero?
    end

    def process_overlap_batch(state)
      operations = 0
      groups = state[:overlap_groups]
      while operations < OVERLAP_BATCH_SIZE && state[:overlap_group_index] < groups.length
        group = groups[state[:overlap_group_index]]
        records = group[:records]
        count = records.length
        if count < 2 || group[:i] >= count - 1
          state[:overlap_group_index] += 1
          next
        end

        if group[:j] >= count
          group[:i] += 1
          group[:j] = group[:i] + 1
          next
        end

        first = records[group[:i]]
        second = records[group[:j]]
        axis = group[:axis]
        if second[:bounds][:min][axis] > first[:bounds][:max][axis] + CONTACT_TOLERANCE_INCHES
          skipped = count - group[:j]
          state[:overlap_processed_pairs] += skipped
          group[:i] += 1
          group[:j] = group[:i] + 1
          operations += 1
          next
        end

        group[:j] += 1
        state[:overlap_processed_pairs] += 1
        operations += 1
        next unless bounds_overlap?(first[:bounds], second[:bounds])

        overlap = polygon_overlap_area(first, second)
        next unless overlap > CONTACT_TOLERANCE_INCHES * CONTACT_TOLERANCE_INCHES

        state[:overlaps][first[:id]] += overlap
        state[:overlaps][second[:id]] += overlap
      end

      ratio = state[:overlap_processed_pairs].to_f / [state[:overlap_total_pairs], 1].max
      notify_calculation_progress(
        state,
        55.0 + [ratio, 1.0].min * 35.0,
        "已检查 #{state[:overlap_processed_pairs]}/#{state[:overlap_total_pairs]} 组潜在面关系"
      )
      prepare_aggregate_stage(state) if state[:overlap_group_index] >= groups.length
    end

    def prepare_aggregate_stage(state)
      state[:stage] = :aggregate
      state[:aggregate_index] = 0
      state[:totals] = Hash.new { |hash, key| hash[key] = { area_sq_in: 0.0, face_count: 0 } }
      notify_calculation_progress(state, 90.0, '汇总各材质净面积', force: true)
    end

    def process_aggregate_batch(state)
      limit = [state[:aggregate_index] + AGGREGATE_BATCH_SIZE, state[:records].length].min
      while state[:aggregate_index] < limit
        record = state[:records][state[:aggregate_index]]
        state[:aggregate_index] += 1
        covered_area = [state[:overlaps][record[:id]].to_f, record[:area]].min
        if covered_area > 0
          state[:scan_stats][:excluded_contact_faces] += 1
          state[:scan_stats][:excluded_contact_area_sq_in] += covered_area
        end
        billable_area = record[:area] - covered_area
        next unless billable_area > 0

        state[:totals][record[:name]][:area_sq_in] += billable_area
        state[:totals][record[:name]][:face_count] += 1
      end
      ratio = state[:aggregate_index].to_f / [state[:records].length, 1].max
      notify_calculation_progress(state, 90.0 + ratio * 8.0, "已汇总 #{state[:aggregate_index]}/#{state[:records].length} 个计价面")
      finish_area_calculation(state) if state[:aggregate_index] >= state[:records].length
    end

    def finish_area_calculation(state)
      UI.stop_timer(@calculation_timer) if @calculation_timer
      @calculation_timer = nil
      @geometry_cache = {
        model_object_id: state[:model].object_id,
        selected_signature: state[:selected_signature],
        totals: state[:totals],
        scan_stats: state[:scan_stats],
        elapsed_seconds: Time.now - state[:started_at]
      }
      @geometry_dirty = false
      result = calculate_budget(state[:model], @geometry_cache)
      @dialog.execute_script("window.MaterialBudget.update(#{JSON.generate(result)});") if @dialog && @dialog.visible?
      notify_calculation_progress(
        state,
        100.0,
        "完成：#{state[:records].length} 个计价面，用时 #{format('%.1f', @geometry_cache[:elapsed_seconds])} 秒",
        force: true
      )
      @calculation_state = nil
    end

    def progress_steps(stage, overall)
      definitions = [
        [:scan, '扫描已吸取材质面', 0.0, 55.0],
        [:overlap, '筛选并计算重叠', 55.0, 90.0],
        [:aggregate, '汇总材质净面积', 90.0, 98.0],
        [:complete, '更新预算界面', 98.0, 100.0]
      ]
      current_index = definitions.index { |item| item[0] == stage } || (overall >= 100 ? 3 : 0)
      definitions.each_with_index.map do |item, index|
        _key, name, start_percent, end_percent = item
        local = if overall >= end_percent
                  100
                elsif overall <= start_percent
                  0
                else
                  ((overall - start_percent) / (end_percent - start_percent) * 100).round
                end
        status = index < current_index ? '已完成' : (index == current_index ? '进行中' : '等待中')
        status = '已完成' if overall >= 100
        { name: name, status: status, percent: local }
      end
    end

    def notify_calculation_progress(state, overall, detail, force: false)
      return unless @dialog && @dialog.visible?

      now = Time.now
      if !force && overall > 0.0 && overall < 100.0 &&
         state[:last_progress_at] && (now - state[:last_progress_at]) < PROGRESS_THROTTLE_SECONDS
        return
      end

      state[:last_progress_at] = now
      stage = overall >= 100 ? :complete : state[:stage]
      payload = {
        overall_percent: [[overall, 0.0].max, 100.0].min.round(1),
        stage: stage.to_s,
        detail: detail,
        current_material: state[:current_material].to_s,
        processed_entities: state[:processed_entities],
        selected_faces: state[:records].length,
        elapsed_seconds: (now - state[:started_at]).round(1),
        steps: progress_steps(stage, overall)
      }
      @dialog.execute_script("window.MaterialBudget.progress(#{JSON.generate(payload)});")
    end

    def refresh_budget
      return unless @dialog && @dialog.visible?

      model = Sketchup.active_model
      unless geometry_cache_valid?(model)
        start_area_calculation('缓存失效，重新计算')
        return
      end

      result = calculate_budget(model, @geometry_cache)
      script = "window.MaterialBudget.update(#{JSON.generate(result)});"
      @dialog.execute_script(script)
    rescue StandardError => error
      notify_error("预算计算失败：#{error.message}")
      puts("#{PLUGIN_ID}: #{error.full_message}")
    end

    def schedule_refresh
      return unless @dialog && @dialog.visible?
      return if @refresh_timer

      @refresh_timer = UI.start_timer(REFRESH_DELAY_SECONDS, false) do
        @refresh_timer = nil
        start_area_calculation('模型几何已变化')
      end
    end

    def calculate_budget(model, geometry_cache = nil)
      selected_names = selected_material_names(model)
      if geometry_cache
        scan_stats = geometry_cache[:scan_stats]
        totals = geometry_cache[:totals]
      else
        scan_stats = { skipped_entities: 0, excluded_contact_faces: 0, excluded_contact_area_sq_in: 0.0 }
        totals = {}
      end

      prices = model_prices(model)
      library = model_price_library(model)
      library_index = price_library_index(library)
      materials = totals.map do |name, values|
        raw_area = numeric_or_zero(values[:area_sq_in])
        area_m2 = raw_area * M2_PER_SQUARE_INCH
        exact_entry = library_index[normalized_material_name(name)]
        mapped_entry = exact_entry ? nil : confirmed_mapping_entry(name, library)
        entry = exact_entry || mapped_entry
        suggestions = entry ? [] : ai_material_suggestions(name, library)
        override = prices.key?(name) ? prices[name].to_f : nil
        components = if override
                       {
                         material_unit_price: override,
                         labor_unit_price: 0.0,
                         machinery_unit_price: 0.0,
                         management_unit_price: 0.0,
                         profit_unit_price: 0.0,
                         comprehensive_unit_price: override
                       }
                     elsif entry
                       entry
                     else
                       {
                         material_unit_price: 0.0,
                         labor_unit_price: 0.0,
                         machinery_unit_price: 0.0,
                         management_unit_price: 0.0,
                         profit_unit_price: 0.0,
                         comprehensive_unit_price: 0.0
                       }
                     end
        price = numeric_or_zero(components[:comprehensive_unit_price])
        {
          name: name,
          color_hex: material_color_hex(model, name),
          area_m2: area_m2.round(3),
          unit_price: price.round(2),
          subtotal: (area_m2 * price).round(2),
          face_count: values[:face_count],
          match_status: override ? '手动定价' : (mapped_entry ? '工作室映射' : (entry ? '已匹配' : '待人工确认')),
          has_manual_override: !override.nil?,
          has_studio_mapping: !mapped_entry.nil?,
          standard_code: entry ? entry[:standard_code] : '',
          category: entry ? entry[:category] : '未分类',
          standard_name: entry ? entry[:standard_name] : '',
          material_unit_price: numeric_or_zero(components[:material_unit_price]).round(2),
          labor_unit_price: numeric_or_zero(components[:labor_unit_price]).round(2),
          machinery_unit_price: numeric_or_zero(components[:machinery_unit_price]).round(2),
          management_unit_price: numeric_or_zero(components[:management_unit_price]).round(2),
          profit_unit_price: numeric_or_zero(components[:profit_unit_price]).round(2),
          material_subtotal: (area_m2 * numeric_or_zero(components[:material_unit_price])).round(2),
          labor_subtotal: (area_m2 * numeric_or_zero(components[:labor_unit_price])).round(2),
          machinery_subtotal: (area_m2 * numeric_or_zero(components[:machinery_unit_price])).round(2),
          management_subtotal: (area_m2 * numeric_or_zero(components[:management_unit_price])).round(2),
          profit_subtotal: (area_m2 * numeric_or_zero(components[:profit_unit_price])).round(2),
          source_region: entry ? entry[:source_region] : '',
          price_date: entry ? entry[:price_date] : '',
          source_url: entry ? entry[:source_url] : '',
          ai_suggestions: suggestions
        }
      end
      materials.sort_by! { |item| [-item[:subtotal], item[:name].downcase] }

      # Avoid Enumerable#sum because some SketchUp extensions redefine its
      # empty-array behavior and return nil instead of a numeric zero.
      total_area_m2 = materials.inject(0.0) do |sum, item|
        sum + numeric_or_zero(item[:area_m2])
      end
      total_budget = materials.inject(0.0) do |sum, item|
        sum + numeric_or_zero(item[:subtotal])
      end
      total_material_cost = materials.inject(0.0) { |sum, item| sum + numeric_or_zero(item[:material_subtotal]) }
      total_labor_cost = materials.inject(0.0) { |sum, item| sum + numeric_or_zero(item[:labor_subtotal]) }
      total_machinery_cost = materials.inject(0.0) { |sum, item| sum + numeric_or_zero(item[:machinery_subtotal]) }
      total_management_cost = materials.inject(0.0) { |sum, item| sum + numeric_or_zero(item[:management_subtotal]) }
      total_profit_cost = materials.inject(0.0) { |sum, item| sum + numeric_or_zero(item[:profit_subtotal]) }
      baseline = budget_baseline(model)
      baseline_amount = baseline ? baseline[:amount] : nil
      budget_delta = baseline_amount ? total_budget - baseline_amount : nil
      target_budget = project_budget(model)
      remaining_budget = target_budget ? target_budget - total_budget : nil
      linked_file = linked_price_file(model)
      sync_info = linked_sync_info(model)

      {
        model_name: model.title.to_s.empty? ? '未命名模型' : model.title.to_s,
        currency: 'CNY',
        materials: materials,
        price_library_options: library.map do |entry|
          { standard_code: entry[:standard_code], standard_name: entry[:standard_name], category: entry[:category] }
        end,
        mapping_history: mapping_history(model).last(50).reverse,
        studio_mapping_count: studio_material_mappings.length,
        deepseek_configured: !!(@deepseek_api_key && !@deepseek_api_key.empty?),
        deepseek_model: deepseek_model,
        deepseek_endpoint: deepseek_endpoint,
        selected_materials: selected_names.sort,
        total_area_m2: total_area_m2.round(3),
        total_budget: total_budget.round(2),
        project_budget: target_budget&.round(2),
        remaining_budget: remaining_budget&.round(2),
        budget_usage_percent: target_budget ? (total_budget / target_budget * 100.0).round(1) : nil,
        total_material_cost: total_material_cost.round(2),
        total_labor_cost: total_labor_cost.round(2),
        total_machinery_cost: total_machinery_cost.round(2),
        total_management_cost: total_management_cost.round(2),
        total_profit_cost: total_profit_cost.round(2),
        baseline_budget: baseline_amount&.round(2),
        baseline_captured_at: baseline ? baseline[:captured_at] : '',
        budget_delta: budget_delta&.round(2),
        price_library_count: library.length,
        linked_price_file: linked_file,
        linked_file_exists: !linked_file.empty? && File.file?(linked_file),
        linked_file_name: linked_file.empty? ? '' : File.basename(linked_file),
        linked_synced_at: sync_info['synced_at'].to_s,
        linked_row_count: numeric_or_zero(sync_info['row_count']).to_i,
        unmatched_count: materials.count { |item| item[:match_status] == '待人工确认' },
        unpriced_count: materials.count { |item| item[:unit_price].zero? },
        skipped_entities: scan_stats[:skipped_entities],
        excluded_contact_faces: scan_stats[:excluded_contact_faces],
        excluded_contact_area_m2: (
          scan_stats[:excluded_contact_area_sq_in] * M2_PER_SQUARE_INCH
        ).round(3),
        updated_at: Time.now.strftime('%Y-%m-%d %H:%M:%S')
      }
    end

    def projected_triangles_for(record, axis)
      if record[:projected_triangles] && record[:projected_axis] == axis
        return record[:projected_triangles]
      end

      unless record[:triangles]
        face = record[:face]
        record[:triangles] = if face && face.valid?
                               face_triangles(face, record[:transform])
                             else
                               []
                             end
      end
      record[:projected_axis] = axis
      record[:projected_triangles] = record[:triangles].map do |triangle|
        pts = ensure_counter_clockwise(project_triangle(triangle, axis))
        { pts: pts, bounds: bounds_2d(pts) }
      end
    end

    def polygon_overlap_area(first, second)
      axis = dominant_axis(first[:normal])
      scale = [first[:normal].x, first[:normal].y, first[:normal].z][axis].abs
      return 0.0 if scale < 0.000001

      first_projected = projected_triangles_for(first, axis)
      second_projected = projected_triangles_for(second, axis)
      return 0.0 if first_projected.empty? || second_projected.empty?

      total = 0.0
      first_projected.each do |first_tri|
        second_projected.each do |second_tri|
          next unless bounds_2d_overlap?(first_tri[:bounds], second_tri[:bounds])

          clipped = clip_convex_polygon(first_tri[:pts], second_tri[:pts])
          total += polygon_area_2d(clipped) / scale if clipped.length >= 3
        end
      end
      [total, first[:area], second[:area]].min
    end

    def face_triangles(face, transform)
      mesh = face.mesh(0)
      mesh.polygons.each_with_object([]) do |polygon, triangles|
        points = polygon.map do |index|
          mesh.point_at(index.abs).transform(transform)
        end
        next if points.length < 3

        (1...(points.length - 1)).each do |index|
          triangles << [points[0], points[index], points[index + 1]]
        end
      end
    end

    def world_normal(face, transform, transformed_points = nil)
      points = transformed_points || face.outer_loop.vertices.map { |vertex| vertex.position.transform(transform) }
      nx = 0.0
      ny = 0.0
      nz = 0.0
      count = points.length
      if count >= 3
        count.times do |index|
          current = points[index]
          following = points[(index + 1) % count]
          nx += (current.y - following.y) * (current.z + following.z)
          ny += (current.z - following.z) * (current.x + following.x)
          nz += (current.x - following.x) * (current.y + following.y)
        end
      end
      normal = Geom::Vector3d.new(nx, ny, nz)
      if normal.length > 0.000001
        normal.normalize!
      else
        normal = face.normal.transform(transform)
        normal.normalize! if normal.length > 0.000001
      end
      components = [normal.x, normal.y, normal.z]
      first_significant = components.find { |value| value.abs > 0.000001 }
      normal.reverse! if first_significant && first_significant < 0
      normal
    end

    def dominant_axis(normal)
      [normal.x.abs, normal.y.abs, normal.z.abs].each_with_index.max[1]
    end

    def project_triangle(triangle, axis)
      triangle.map do |point|
        case axis
        when 0 then [point.y, point.z]
        when 1 then [point.x, point.z]
        else [point.x, point.y]
        end
      end
    end

    def bounds_2d(points)
      {
        min_x: points.map { |point| point[0] }.min,
        max_x: points.map { |point| point[0] }.max,
        min_y: points.map { |point| point[1] }.min,
        max_y: points.map { |point| point[1] }.max
      }
    end

    def bounds_2d_overlap?(first, second)
      first[:min_x] <= second[:max_x] + CONTACT_TOLERANCE_INCHES &&
        second[:min_x] <= first[:max_x] + CONTACT_TOLERANCE_INCHES &&
        first[:min_y] <= second[:max_y] + CONTACT_TOLERANCE_INCHES &&
        second[:min_y] <= first[:max_y] + CONTACT_TOLERANCE_INCHES
    end

    def ensure_counter_clockwise(points)
      polygon_signed_area_2d(points) < 0 ? points.reverse : points
    end

    def clip_convex_polygon(subject, clip_polygon)
      output = subject.dup
      clip_polygon.each_with_index do |clip_start, index|
        clip_end = clip_polygon[(index + 1) % clip_polygon.length]
        input = output
        output = []
        break if input.empty?

        previous = input[-1]
        input.each do |current|
          current_inside = inside_clip_edge?(current, clip_start, clip_end)
          previous_inside = inside_clip_edge?(previous, clip_start, clip_end)
          if current_inside
            output << line_intersection_2d(previous, current, clip_start, clip_end) unless previous_inside
            output << current
          elsif previous_inside
            output << line_intersection_2d(previous, current, clip_start, clip_end)
          end
          previous = current
        end
      end
      output
    end

    def inside_clip_edge?(point, edge_start, edge_end)
      edge = [edge_end[0] - edge_start[0], edge_end[1] - edge_start[1]]
      relative = [point[0] - edge_start[0], point[1] - edge_start[1]]
      edge_length = Math.sqrt(edge[0] * edge[0] + edge[1] * edge[1])
      cross_2d(edge, relative) >= -CONTACT_TOLERANCE_INCHES * edge_length
    end

    def line_intersection_2d(start_point, end_point, clip_start, clip_end)
      segment = [end_point[0] - start_point[0], end_point[1] - start_point[1]]
      clip_edge = [clip_end[0] - clip_start[0], clip_end[1] - clip_start[1]]
      offset = [clip_start[0] - start_point[0], clip_start[1] - start_point[1]]
      denominator = cross_2d(segment, clip_edge)
      return end_point if denominator.abs < 0.0000000001

      factor = cross_2d(offset, clip_edge) / denominator
      [start_point[0] + factor * segment[0], start_point[1] + factor * segment[1]]
    end

    def cross_2d(first, second)
      first[0] * second[1] - first[1] * second[0]
    end

    def polygon_signed_area_2d(points)
      return 0.0 if points.length < 3

      points.each_with_index.inject(0.0) do |sum, (point, index)|
        following = points[(index + 1) % points.length]
        sum + point[0] * following[1] - following[0] * point[1]
      end / 2.0
    end

    def polygon_area_2d(points)
      polygon_signed_area_2d(points).abs
    end

    def plane_key(normal, points)
      distance = normal.x * points[0].x + normal.y * points[0].y + normal.z * points[0].z
      normal_key = [normal.x, normal.y, normal.z].map do |value|
        (value / 0.00001).round
      end
      (normal_key + [(distance / CONTACT_TOLERANCE_INCHES).round]).join(',')
    end

    def point_bounds(points)
      coordinates = points.map { |point| [point.x, point.y, point.z] }
      {
        min: 3.times.map { |axis| coordinates.map { |item| item[axis] }.min },
        max: 3.times.map { |axis| coordinates.map { |item| item[axis] }.max }
      }
    end

    def bounds_overlap?(first, second)
      3.times.all? do |axis|
        first[:min][axis] <= second[:max][axis] + CONTACT_TOLERANCE_INCHES &&
          second[:min][axis] <= first[:max][axis] + CONTACT_TOLERANCE_INCHES
      end
    end

    def billable_surface_material(front_material, back_material)
      # One geometric face represents one finish surface. The SketchUp front
      # side is the exterior/billable side; only fall back to the back side
      # when the front has no material at all.
      front_material || back_material
    end

    def numeric_or_zero(value)
      return value.to_f if value.is_a?(Numeric) && value.finite?

      cleaned = value.to_s.strip.gsub(/[￥¥,，]/, '')
      return 0.0 if cleaned.empty?

      parsed = Float(cleaned)
      parsed.finite? ? parsed : 0.0
    rescue ArgumentError, TypeError
      0.0
    end

    def export_full_csv
      model = Sketchup.active_model
      unless geometry_cache_valid?(model)
        start_area_calculation('导出前重新计算')
        notify_info('面积正在重新计算，完成后请再次点击“导出完整预算表”。')
        return
      end
      result = calculate_budget(model, @geometry_cache)
      default_name = "#{safe_filename(result[:model_name])}_完整材质预算.csv"
      path = UI.savepanel('导出完整材质预算表', nil, default_name)
      return unless path

      CSV.open(path, 'wb', write_headers: true, headers: true, encoding: 'UTF-8') do |csv|
        csv << [
          "\uFEFFSU材质名称", '匹配状态', '标准编码', '分类', '匹配标准材质', '着色面积(㎡)',
          '材料单价(元/㎡)', '人工单价(元/㎡)', '机械单价(元/㎡)', '管理费(元/㎡)',
          '利润(元/㎡)', '综合单价(元/㎡)', '材料费小计(元)', '人工费小计(元)',
          '综合小计(元)', '着色面数', '价格地区', '价格日期', '来源URL'
        ]
        result[:materials].each do |item|
          csv << [
            item[:name],
            item[:match_status],
            item[:standard_code],
            item[:category],
            item[:standard_name],
            format('%.3f', item[:area_m2]),
            format('%.2f', item[:material_unit_price]),
            format('%.2f', item[:labor_unit_price]),
            format('%.2f', item[:machinery_unit_price]),
            format('%.2f', item[:management_unit_price]),
            format('%.2f', item[:profit_unit_price]),
            format('%.2f', item[:unit_price]),
            format('%.2f', item[:material_subtotal]),
            format('%.2f', item[:labor_subtotal]),
            format('%.2f', item[:subtotal]),
            item[:face_count],
            item[:source_region],
            item[:price_date],
            item[:source_url]
          ]
        end
        csv << []
        csv << ['合计', '', '', '', '', format('%.3f', result[:total_area_m2]), '', '', '', '', '', '',
                format('%.2f', result[:total_material_cost]), format('%.2f', result[:total_labor_cost]),
                format('%.2f', result[:total_budget]), '', '', '', '']
        csv << ['预算基准', '', '', '', '', '', '', '', '', '', '', '', '', '',
                result[:baseline_budget] ? format('%.2f', result[:baseline_budget]) : '未设置', '', '', '', '']
        csv << ['预算差额', '', '', '', '', '', '', '', '', '', '', '', '', '',
                result[:budget_delta] ? format('%+.2f', result[:budget_delta]) : '未设置', '', '', '', '']
        csv << ['项目总预算', '', '', '', '', '', '', '', '', '', '', '', '', '',
                result[:project_budget] ? format('%.2f', result[:project_budget]) : '未设置', '', '', '', '']
        csv << ['剩余可用预算', '', '', '', '', '', '', '', '', '', '', '', '', '',
                result[:remaining_budget] ? format('%+.2f', result[:remaining_budget]) : '未设置', '', '', '', '']
        csv << []
        csv << ['AI材质映射记录']
        csv << ['SU材质', 'AI建议', 'AI置信度', 'AI理由', '人工选择', '最终结果', '确认时间']
        result[:mapping_history].reverse.each do |record|
          csv << [record['source_material'], record['ai_suggestion'], record['ai_confidence'], record['ai_reason'],
                  record['human_choice'], record['final_result'], record['confirmed_at']]
        end
      end
      notify_info("完整预算表已导出：#{path}")
    rescue StandardError => error
      notify_error("导出失败：#{error.message}")
    end

    def safe_filename(name)
      cleaned = name.gsub(/[\\\/:*?"<>|]/, '_').strip
      cleaned.empty? ? 'SketchUp模型' : cleaned
    end

    def notify_error(message)
      return unless @dialog

      @dialog.execute_script("window.MaterialBudget.error(#{JSON.generate(message)});")
    end

    def notify_info(message)
      return unless @dialog

      @dialog.execute_script("window.MaterialBudget.info(#{JSON.generate(message)});")
    end

    def attach_model_observer(model)
      return unless model
      return if @observed_model == model

      @model_observer ||= BudgetModelObserver.new
      @materials_observer ||= BudgetMaterialsObserver.new
      model.add_observer(@model_observer)
      model.materials.add_observer(@materials_observer)
      @observed_model = model
    end

    unless file_loaded?(__FILE__)
      command = UI::Command.new('材质实时预算') { show_dialog }
      command.menu_text = '材质实时预算'
      command.tooltip = '根据SU材质着色面积实时计算预算'
      command.status_bar_text = '打开材质实时预算面板'
      small_icon_path = File.join(__dir__, 'toolbar_icon_24.png')
      large_icon_path = File.join(__dir__, 'toolbar_icon_64.png')
      svg_icon_path = File.join(__dir__, 'toolbar_icon.svg')
      command.small_icon = File.file?(small_icon_path) ? small_icon_path : svg_icon_path
      command.large_icon = File.file?(large_icon_path) ? large_icon_path : svg_icon_path

      menu = UI.menu('Extensions')
      menu.add_item(command)

      @toolbar = UI::Toolbar.new('材质实时预算')
      @toolbar.add_item(command)
      if @toolbar.get_last_state == TB_HIDDEN
        @toolbar.restore
      else
        @toolbar.show
      end

      @app_observer = BudgetAppObserver.new
      Sketchup.add_observer(@app_observer)
      attach_model_observer(Sketchup.active_model)

      file_loaded(__FILE__)
    end
  end
end
