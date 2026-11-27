# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module StudioTools
  module MaterialBudget
    MINIMUM_SKETCHUP_VERSION = 20

    if Sketchup.version.to_i < MINIMUM_SKETCHUP_VERSION
      UI.messagebox('材质实时预算 v0.9.0 需要 SketchUp 2020 或更高版本。')
    else
      EXTENSION = SketchupExtension.new(
        '材质实时预算',
        File.join(__dir__, 'su_material_budget', 'main')
      )
      EXTENSION.description = '支持 SketchUp 2020 及以上版本；提供AI材质推荐、人工确认、工作室映射词库、预算、无Excel依赖XLSX关联、模型高亮定位和面积计算。'
      EXTENSION.version = '0.9.0'
      EXTENSION.creator = 'Studio Tools'
      EXTENSION.copyright = '2026 Studio Tools'

      Sketchup.register_extension(EXTENSION, true)
    end
  end
end
