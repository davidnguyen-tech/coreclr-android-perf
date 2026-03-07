using Android.App;
using Android.OS;
using Android.Widget;

namespace hello_custom;

[Activity(Label = "Hello Custom", MainLauncher = true)]
public class MainActivity : Activity
{
    protected override void OnCreate(Bundle? savedInstanceState)
    {
        base.OnCreate(savedInstanceState);

        var textView = new TextView(this) { Text = "Hello from custom app!" };
        SetContentView(textView);
    }
}
