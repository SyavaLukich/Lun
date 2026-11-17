npc.b3d
=======

Модель человека взята из mods/PLAYER/mcl_skins/models/mcl_armor_character.b3d
(проект VoxeLibre); она происходит от character.blend из Minetest Game.
Авторы и лицензия (CC BY-SA 3.0) перечислены в ../LICENSE.txt.

Модель рассчитана на классическую текстуру скина 64x32, содержит
695 кадров при 60 fps и использует кадры character.b3d:
  stand 0..79, walk 168..187, run 440..459, sit 81..160,
  lay 162..166, mine 189..198.

Тест tests/smart_npc_engine.lua проверяет, что все диапазоны
из world.lua укладываются в число кадров модели.

Текстуры скинов (textures/npc_skin_*.png) и портреты
(textures/npc_portrait_*.png) нарисованы генератором
tools/gen_textures.py специально для этого мода (CC0).
