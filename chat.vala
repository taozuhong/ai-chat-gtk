using Gtk;
using Soup;

[GtkTemplate(ui = "/app/chat.ui")]
public class ChatWindow : Gtk.ApplicationWindow {
    [GtkChild]
    private unowned Gtk.Entry entry_api_url;
    [GtkChild]
    private unowned Gtk.Entry entry_api_key;
    [GtkChild]
    private unowned Gtk.Entry entry_api_model;
    [GtkChild]
    private unowned Gtk.Entry entry_prompt;
    [GtkChild]
    private unowned Gtk.ListBox view_messages;
    [GtkChild]
    private unowned Gtk.Button button_send;
    [GtkChild]
    private unowned Gtk.ScrolledWindow scroll_window;

    // API 配置 (默认指向 OpenAI，可改为本地 Ollama/LM Studio 地址)
    private const string API_URL = "http://localhost:11434/v1";
    private const int BIND_FLAGS = BindingFlags.SYNC_CREATE | BindingFlags.BIDIRECTIONAL;

    // 对话历史 (简单实现，保留上下文)
    private Json.Array conversation_history = new Json.Array();

    public ChatWindow (Gtk.Application app) {
        Object (application: app);

        this.entry_api_url.text = API_URL;
        this.entry_api_model.text = "qwen";
    }

    [GtkCallback]
    private void button_send_clicked_handler () {
        string text = this.entry_prompt.get_text ().strip ();
        string key = this.entry_api_key.get_text ().strip ();

        if (text.length == 0) return;
        if (key.length == 0) {
            // 如果没有输入 Key，尝试使用环境变量
            key = Environment.get_variable ("OPENAI_API_KEY") ?? "";
        }

        // 1. 显示用户消息
        add_message_bubble ("You", text);
        this.entry_prompt.set_text (""); // 清空输入
        this.button_send.set_sensitive (false); // 禁用按钮

        // 2. 添加到历史记录
        var user_msg = new Json.Object();
        user_msg.set_string_member("role", "user");
        user_msg.set_string_member("content", text);
        conversation_history.add_object_element(user_msg);

        // 3. 准备助手消息的占位符
        var assistant_bubble = add_message_bubble ("Assistant", "正在思考...");
        
        // 4. 启动异步请求
        send_request_async.begin (key, assistant_bubble);
    }

    // 添加消息气泡
    private Gtk.Label add_message_bubble (string author, string text) {
        var label = new Gtk.Label (@"$author: $text");
        label.wrap = true;
        label.wrap_mode = Pango.WrapMode.WORD_CHAR;
        label.halign = Gtk.Align.START;
        label.margin_top = 4;
        label.margin_bottom = 4;
        label.margin_start = 8;
        label.margin_end = 8;
        label.selectable = true;
        
        this.view_messages.append (label);
        
        // 滚动到底部
        Idle.add(() => {
            var adj = this.scroll_window.vadjustment;
            adj.set_value (adj.upper - adj.page_size);
            return false;
        });
        
        return label;
    }

    // 异步发送请求并处理流式响应
    private async void send_request_async (string api_key, Gtk.Label response_label) {
        var session = new Soup.Session ();
        var message = new Soup.Message ("POST", "%s/chat/completions".printf(this.entry_api_url.text));

        // 构建请求体 JSON
        var builder = new Json.Builder ();
        builder.begin_object ();
        builder.set_member_name ("model");
        builder.add_string_value (this.entry_api_model.text);
        builder.set_member_name ("stream");
        builder.add_boolean_value (true); // 开启流式
        builder.set_member_name ("messages");
        builder.begin_array ();
        
        // 添加历史对话
        foreach (var node in conversation_history.get_elements()) {
            builder.add_value(node);
        }
        
        builder.end_array ();
        builder.end_object ();

        var generator = new Json.Generator ();
        generator.root = builder.get_root ();
        string json_body = generator.to_data (null);

        message.set_request_body_from_bytes ("application/json", new Bytes (json_body.data));

        // 设置 Headers
        message.request_headers.append ("Authorization", @"Bearer $api_key");
        message.request_headers.append ("Content-Type", "application/json");

        // 用于累积完整的回复
        var full_response = new StringBuilder ();

        try {
            // 发送请求
            InputStream stream = yield session.send_async (message, Priority.DEFAULT, null);

            // 处理流式数据
            var data_input = new DataInputStream (stream);
            string line;

            while ((line = yield data_input.read_line_async (Priority.DEFAULT, null)) != null) {
                // SSE 格式解析: "data: {...}"
                if (line.has_prefix ("data: ")) {
                    string json_str = line.substring (6);

                    if (json_str == "[DONE]") {
                        break;
                    }

                    // 解析 JSON 片段
                    var parser = new Json.Parser ();
                    try {
                        parser.load_from_data (json_str);
                        var root = parser.get_root ().get_object ();

                        // OpenAI 格式: choices[0].delta.content
                        if (root.has_member ("choices")) {
                            var choices = root.get_array_member ("choices");
                            var first_choice = choices.get_object_element (0);
                            
                            if (first_choice.has_member ("delta")) {
                                var delta = first_choice.get_object_member ("delta");
                                if (delta.has_member ("content")) {
                                    string chunk = delta.get_string_member ("content");
                                    full_response.append (chunk);

                                    // 更新 UI (必须在主线程安全地进行，Idle.add 确保这一点)
                                    string current_text = full_response.str;
                                    Idle.add(() => {
                                        response_label.set_text (@"Assistant: $current_text");
                                        // 继续滚动到底部
                                        var adj = this.scroll_window.vadjustment;
                                        adj.set_value (adj.upper - adj.page_size);
                                        return false;
                                    });
                                }
                            }
                        }
                    } catch (Error e) {
                        // 解析错误通常意味着接收到空行或不完整数据，忽略继续
                        stderr.printf ("JSON Parse Error: %s\n", e.message);
                    }
                }
            }

            // 请求完成，将助手回复加入历史
            var assistant_msg = new Json.Object();
            assistant_msg.set_string_member("role", "assistant");
            assistant_msg.set_string_member("content", full_response.str);
            conversation_history.add_object_element(assistant_msg);

        } catch (Error e) {
            stderr.printf ("Network Error: %s\n", e.message);
            Idle.add(() => {
                response_label.set_text (@"Error: $(e.message)");
                return false;
            });
        } finally {
            Idle.add(() => {
                this.button_send.set_sensitive (true); // 恢复按钮
                return false;
            });
        }
    }
}