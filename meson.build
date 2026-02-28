project('ai-chat-gtk4', ['vala', 'c'], version: '1.0.0')

# 依赖项
dependencies = [
    dependency('gtk4'),
    dependency('libsoup-3.0'),
    dependency('json-glib-1.0'),
]

gnome=import('gnome')
resources = gnome.compile_resources('resources', 'chat.gresource.xml')

sources = [
    'main.vala',
    'chat.vala',
]

# 构建可执行文件
executable(
    'ai-chat-gtk4',
    sources,
    resources,
    dependencies: dependencies,
    install: true,
)