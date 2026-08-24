package dev.comfyfluffy.caustica.build

import com.sun.jdi.Bootstrap
import com.sun.jdi.ReferenceType
import com.sun.jdi.VirtualMachine
import com.sun.jdi.connect.AttachingConnector
import com.sun.jdi.connect.Connector
import org.gradle.api.DefaultTask
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.Optional
import org.gradle.api.tasks.TaskAction

abstract class HotswapTask extends DefaultTask {
    @Internal
    abstract DirectoryProperty getClassesDir()

    @Input
    @Optional
    abstract Property<String> getHost()

    @Input
    @Optional
    abstract Property<Integer> getPort()

    @TaskAction
    void hotswap() {
        String targetHost = host.getOrElse("localhost")
        int targetPort = port.getOrElse(5005)
        File dir = classesDir.get().asFile
        if (!dir.exists()) {
            logger.error("[Caustica HotSwap] Classes directory not found: ${dir}")
            return
        }

        def vmm = Bootstrap.virtualMachineManager()
        AttachingConnector connector = vmm.attachingConnectors().find { it.name().contains("SocketAttach") }
        if (connector == null) {
            logger.error("[Caustica HotSwap] SocketAttach connector not found in current JDK.")
            return
        }

        Map<String, Connector.Argument> connArgs = connector.defaultArguments()
        connArgs.get("hostname").setValue(targetHost)
        connArgs.get("port").setValue(String.valueOf(targetPort))

        logger.lifecycle("[Caustica HotSwap] Connecting to Minecraft JDWP on ${targetHost}:${targetPort}...")
        VirtualMachine vm
        try {
            vm = connector.attach(connArgs)
        } catch (Exception e) {
            logger.error("\u001B[31m[Caustica HotSwap] 无法连接到游戏 (${targetHost}:${targetPort}): ${e.message}\u001B[0m")
            logger.error("\u001B[33m请确认游戏已通过带有 5005 调试参数的 .bat 脚本启动！\u001B[0m")
            return
        }

        try {
            if (!vm.canRedefineClasses()) {
                logger.error("[Caustica HotSwap] Target JVM does not support class redefinition.")
                return
            }

            Map<ReferenceType, byte[]> redefineMap = [:]
            int totalClasses = 0
            dir.eachFileRecurse(groovy.io.FileType.FILES) { File classFile ->
                if (!classFile.name.endsWith(".class")) return
                totalClasses++
                String relPath = dir.toPath().relativize(classFile.toPath()).toString()
                String className = relPath.replace(File.separator, ".").replaceAll(/\.class$/, "")

                List<ReferenceType> targetClasses = vm.classesByName(className)
                if (targetClasses != null && !targetClasses.isEmpty()) {
                    byte[] bytes = classFile.bytes
                    targetClasses.each { ReferenceType refType ->
                        redefineMap.put(refType, bytes)
                    }
                }
            }

            if (redefineMap.isEmpty()) {
                logger.warn("[Caustica HotSwap] 目标 JVM 中尚未加载任何匹配的 Caustica 类（共扫描到 ${totalClasses} 个编译类）。")
            } else {
                vm.redefineClasses(redefineMap)
                logger.lifecycle("\u001B[32m[Caustica HotSwap] 成功热重载 ${redefineMap.size()} 个已加载类到 Minecraft 运行中！\u001B[0m")
            }
        } catch (Exception e) {
            logger.error("\u001B[31m[Caustica HotSwap] 热重载类失败: ${e.message}\u001B[0m", e)
            logger.warn("\u001B[33m提示: JVM HotSwap 仅支持修改方法体内容。如果增删了方法或字段，需要重启游戏。\u001B[0m")
        } finally {
            vm.dispose()
        }
    }
}
