var TiebaPureOpenAction = function() {};

TiebaPureOpenAction.prototype = {
    run: function(arguments) {
        arguments.completionFunction({ "url": document.URL });
    },

    finalize: function(arguments) {
        var deepLink = arguments["deepLink"];
        if (typeof deepLink === "string" && deepLink.indexOf("tiebapure://open?") === 0) {
            window.location.assign(deepLink);
            return;
        }

        var errorMessage = arguments["errorMessage"];
        if (typeof errorMessage === "string" && errorMessage.length > 0) {
            window.alert(errorMessage);
        }
    }
};

var ExtensionPreprocessingJS = new TiebaPureOpenAction();
