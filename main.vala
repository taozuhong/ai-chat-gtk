public class ChatApplication : Gtk.Application {
    public ChatApplication () {
        Object (application_id: "com.gnome.AIChat");
    }

    protected override void activate () {
        var win = new ChatWindow (this);
        win.present ();
    }

    public static int main (string[] args) {
        var app = new ChatApplication ();
        return app.run (args);
    }
}
